using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Godot;
using Godot.Collections;

namespace AnotherEarth.Orbital;

/// <summary>
/// Owns the simulation clock and every <see cref="CelestialBody"/> in the scene.
/// <para>Each physics tick it advances <see cref="SimTime"/> and places every body on its orbit before the physics
/// server steps, so ships (RigidBody2D) are integrated by Godot against the gravity areas at the correct positions.</para>
/// <para>It is also the GDScript entry point to the C# solvers: trajectory prediction, transfer planning and
/// course-correction targeting, all of which run on worker threads and report back through a Callable.</para>
/// Find it from GDScript with <c>get_tree().get_first_node_in_group(&amp;"orbital_system")</c>.
/// </summary>
[GlobalClass]
public partial class OrbitalSystem : Node
{
	public const string GroupName = "orbital_system";

	[Signal] public delegate void EphemerisRebuiltEventHandler();
	[Signal] public delegate void TimeWarpChangedEventHandler(int warp);

	/// <summary>Available time warp factors. Warp raises both time scale and tick rate so the physics step stays constant.</summary>
	[Export] public int[] WarpLevels { get; set; } = { 1, 2, 4, 8, 16, 32 };
	/// <summary>Zero the world's default gravity and damping while this system is in the tree.</summary>
	[Export] public bool ZeroSpaceGravity { get; set; } = true;

	/// <summary>Seconds since the epoch. Body positions are a pure function of this value (save/load it to restore the system).</summary>
	public double SimTime { get; set; }
	public bool IsReady => _ephemeris != null;
	public int TimeWarp => WarpLevels.Length > 0 ? WarpLevels[_warpIndex] : 1;
	public int TimeWarpIndex => _warpIndex;
	/// <summary>
	/// Highest warp index currently allowed (-1 = no cap). Lowering it below the current warp drops warp at once;
	/// warp requests above it are clamped. Used to slow time ahead of and during burns.
	/// </summary>
	public int WarpCapIndex
	{
		get => _warpCapIndex;
		set
		{
			_warpCapIndex = value < 0 ? -1 : value;
			if (_warpCapIndex >= 0 && _warpIndex > _warpCapIndex)
				SetTimeWarpIndex(_warpIndex);
		}
	}
	public bool IsWarpCapped => _warpCapIndex >= 0 && _warpCapIndex < WarpLevels.Length - 1;
	/// <summary>Length of one physics tick in simulation seconds (constant across time warp).</summary>
	public double PhysicsDt => 1.0 / _baseTicks;
	public int BodyCount => _bodies.Count;

	internal Ephemeris CurrentEphemeris => _ephemeris;

	/// <summary>
	/// Simulation time that a ship's current position/velocity belong to: the time of the next physics step that will
	/// integrate it. This is SimTime during physics processing after the clock advanced, and SimTime + PhysicsDt
	/// anywhere else (idle frames, or physics callbacks that run before this node). Off-by-one-tick errors here grow
	/// into large phase errors over many tight parking orbits, so all solvers start from this time.
	/// </summary>
	public double StateTime =>
		Engine.IsInPhysicsFrame() && _advancedFrame == Engine.GetPhysicsFrames() ? SimTime : SimTime + PhysicsDt;

	private readonly List<CelestialBody> _bodies = new();
	private Ephemeris _ephemeris;
	private Vector2D[] _positions = System.Array.Empty<Vector2D>();
	private Vector2D[] _velocities = System.Array.Empty<Vector2D>();
	private bool _dirty = true;
	private bool _rebuildQueued;
	private int _warpIndex;
	private int _warpCapIndex = -1;
	private int _baseTicks = 60;
	private int _baseMaxSteps = 8;
	private double _baseTimeScale = 1.0;
	private Variant _savedGravity;
	private Variant _savedLinearDamp;
	private Variant _savedAngularDamp;
	private Rid _space;
	private ulong _advancedFrame = ulong.MaxValue;

	public override void _EnterTree()
	{
		AddToGroup(GroupName);
		// Bodies must be on their orbits before any ship script or the physics step runs.
		ProcessPhysicsPriority = -1000;
	}

	public override void _Ready()
	{
		_baseTicks = Engine.PhysicsTicksPerSecond;
		_baseMaxSteps = Engine.MaxPhysicsStepsPerFrame;
		_baseTimeScale = Engine.TimeScale;
		if (ZeroSpaceGravity)
		{
			_space = GetViewport().World2D.Space;
			_savedGravity = PhysicsServer2D.AreaGetParam(_space, PhysicsServer2D.AreaParameter.Gravity);
			_savedLinearDamp = PhysicsServer2D.AreaGetParam(_space, PhysicsServer2D.AreaParameter.LinearDamp);
			_savedAngularDamp = PhysicsServer2D.AreaGetParam(_space, PhysicsServer2D.AreaParameter.AngularDamp);
			PhysicsServer2D.AreaSetParam(_space, PhysicsServer2D.AreaParameter.Gravity, 0.0f);
			PhysicsServer2D.AreaSetParam(_space, PhysicsServer2D.AreaParameter.LinearDamp, 0.0f);
			PhysicsServer2D.AreaSetParam(_space, PhysicsServer2D.AreaParameter.AngularDamp, 0.0f);
		}
		MarkDirty();
	}

	public override void _ExitTree()
	{
		SetTimeWarpIndex(0);
		if (_space.IsValid)
		{
			PhysicsServer2D.AreaSetParam(_space, PhysicsServer2D.AreaParameter.Gravity, _savedGravity);
			PhysicsServer2D.AreaSetParam(_space, PhysicsServer2D.AreaParameter.LinearDamp, _savedLinearDamp);
			PhysicsServer2D.AreaSetParam(_space, PhysicsServer2D.AreaParameter.AngularDamp, _savedAngularDamp);
			_space = default;
		}
	}

	public override void _PhysicsProcess(double delta)
	{
		if (_dirty)
			RebuildEphemeris();
		SimTime += delta;
		_advancedFrame = Engine.GetPhysicsFrames();
		UpdateBodies();
	}

	#region Bodies

	/// <summary>Request an ephemeris rebuild (called automatically when bodies enter or leave the tree).</summary>
	public void MarkDirty()
	{
		_dirty = true;
		if (!_rebuildQueued && IsInsideTree())
		{
			_rebuildQueued = true;
			Callable.From(() =>
			{
				_rebuildQueued = false;
				if (_dirty && IsInsideTree())
					RebuildEphemeris();
			}).CallDeferred();
		}
	}

	public void RebuildEphemeris()
	{
		_dirty = false;
		List<CelestialBody> found = GetTree().GetNodesInGroup(CelestialBody.GroupName)
			.OfType<CelestialBody>()
			.Where(b => b.IsInsideTree() && !b.IsQueuedForDeletion())
			.ToList();

		int Depth(CelestialBody b)
		{
			int depth = 0;
			for (CelestialBody p = b.ResolveOrbitParent(); p != null && found.Contains(p); p = p.ResolveOrbitParent())
				depth++;
			return depth;
		}

		// Stable sort keeps scene-tree order within a depth.
		List<CelestialBody> ordered = found.Select((b, i) => (b, i, d: Depth(b)))
			.OrderBy(x => x.d).ThenBy(x => x.i).Select(x => x.b).ToList();

		var index = new System.Collections.Generic.Dictionary<CelestialBody, int>();
		for (int i = 0; i < ordered.Count; i++)
			index[ordered[i]] = i;

		var defs = new BodyDef[ordered.Count];
		for (int i = 0; i < ordered.Count; i++)
		{
			CelestialBody body = ordered[i];
			CelestialBody parent = body.ResolveOrbitParent();
			int parentIndex = parent != null && index.TryGetValue(parent, out int pi) ? pi : -1;
			var def = new BodyDef
			{
				Name = body.Name,
				Parent = parentIndex,
				Depth = parentIndex >= 0 ? defs[parentIndex].Depth + 1 : 0,
				Mu = body.Mu,
				Radius = body.Radius,
			};

			if (parentIndex < 0)
			{
				if (!body.PlacementResolved)
				{
					body.FixedPosition = body.GlobalPosition;
					body.PlacementResolved = true;
				}
				def.FixedPosition = body.FixedPosition;
				def.SphereOfInfluence = body.SphereOfInfluence > 0.0 ? body.SphereOfInfluence : CelestialBody.UnlimitedRadius;
			}
			else
			{
				double parentMu = defs[parentIndex].Mu;
				if (body.OrbitFromPlacement && !body.PlacementResolved)
				{
					// Bodies have not been moved yet, so authored positions are still valid.
					Vector2D relative = body.GlobalPosition - parent.GlobalPosition;
					body.SetElements(KeplerElements.Circular(relative, parentMu, SimTime, body.Retrograde));
				}
				body.PlacementResolved = true;
				def.Orbit = body.GetElements();
				if (def.Orbit.SemiMajorAxis <= 0.0)
				{
					GD.PushWarning($"CelestialBody '{body.Name}' has no semi-major axis; placing it at its parent.");
					def.Orbit.SemiMajorAxis = 1e-3;
				}
				def.SphereOfInfluence = body.SphereOfInfluence > 0.0
					? body.SphereOfInfluence
					: def.Orbit.SemiMajorAxis * Math.Pow(body.Mu / parentMu, 0.4);
			}
			def.GravityRadius = body.GravityRange > 0.0 ? body.GravityRange
				: parentIndex < 0 ? CelestialBody.UnlimitedRadius
				: def.SphereOfInfluence;
			defs[i] = def;
		}

		_bodies.Clear();
		_bodies.AddRange(ordered);
		_ephemeris = new Ephemeris(defs);
		_positions = new Vector2D[defs.Length];
		_velocities = new Vector2D[defs.Length];
		for (int i = 0; i < ordered.Count; i++)
		{
			ordered[i].BodyIndex = i;
			ordered[i].ConfigurePhysics(defs[i].GravityRadius, defs[i].SphereOfInfluence);
		}
		UpdateBodies();
		EmitSignal(SignalName.EphemerisRebuilt);
	}

	private void UpdateBodies()
	{
		if (_ephemeris == null)
			return;
		_ephemeris.ComputeStates(SimTime, _positions, _velocities);
		for (int i = 0; i < _bodies.Count; i++)
		{
			CelestialBody body = _bodies[i];
			if (!IsInstanceValid(body))
				continue;
			body.GlobalPosition = _positions[i].ToVector2();
		}
	}

	public int GetBodyIndex(Node body) => body is CelestialBody c && _bodies.Contains(c) ? c.BodyIndex : -1;

	public Node2D GetBody(int index) => index >= 0 && index < _bodies.Count ? _bodies[index] : null;

	public string GetBodyName(int index) => ValidIndex(index) ? _ephemeris.Bodies[index].Name : "";

	public double GetBodyMu(int index) => ValidIndex(index) ? _ephemeris.Bodies[index].Mu : 0.0;

	public double GetBodyRadius(int index) => ValidIndex(index) ? _ephemeris.Bodies[index].Radius : 0.0;

	public double GetBodySphereOfInfluence(int index) => ValidIndex(index) ? _ephemeris.Bodies[index].SphereOfInfluence : 0.0;

	public double GetBodyGravityRange(int index) => ValidIndex(index) ? _ephemeris.Bodies[index].GravityRadius : 0.0;

	public int GetBodyParent(int index) => ValidIndex(index) ? _ephemeris.Bodies[index].Parent : -1;

	public Vector2 GetBodyPosition(int index, double time) =>
		ValidIndex(index) ? _ephemeris.GetPosition(index, time).ToVector2() : Vector2.Zero;

	public Vector2 GetBodyVelocity(int index, double time)
	{
		if (!ValidIndex(index))
			return Vector2.Zero;
		_ephemeris.GetState(index, time, out _, out Vector2D v);
		return v.ToVector2();
	}

	/// <summary>The body whose gravity dominates at <paramref name="position"/> right now, or -1.</summary>
	public int FindDominantBody(Vector2 position) => _ephemeris?.FindDominant(position, _positions) ?? -1;

	/// <summary>World velocity for a circular orbit around <paramref name="body"/> through <paramref name="position"/>.</summary>
	public Vector2 GetCircularVelocity(Vector2 position, int body, bool retrograde)
	{
		if (!ValidIndex(body))
			return Vector2.Zero;
		Vector2D rel = (Vector2D)position - _positions[body];
		double speed = Math.Sqrt(_ephemeris.Bodies[body].Mu / rel.Length);
		Vector2D direction = rel.Normalized().Perpendicular * (retrograde ? -1.0 : 1.0);
		return (_velocities[body] + direction * speed).ToVector2();
	}

	/// <summary>Osculating orbit relative to <paramref name="body"/>: {periapsis, apoapsis, eccentricity, semi_major_axis, period, bound, retrograde, argument_of_periapsis}.</summary>
	public Dictionary GetOrbitInfo(Vector2 position, Vector2 velocity, int body)
	{
		if (!ValidIndex(body))
			return new Dictionary();
		OrbitInfo info = OrbitInfo.FromState((Vector2D)position - _positions[body], (Vector2D)velocity - _velocities[body],
			_ephemeris.Bodies[body].Mu);
		return new Dictionary
		{
			{ "periapsis", info.Periapsis },
			{ "apoapsis", info.Apoapsis },
			{ "eccentricity", info.Eccentricity },
			{ "semi_major_axis", info.SemiMajorAxis },
			{ "period", info.Period },
			{ "bound", info.Bound },
			{ "retrograde", info.AngularMomentum < 0.0 },
			{ "argument_of_periapsis", info.ArgumentOfPeriapsis },
		};
	}

	/// <summary>Points of a body's orbit relative to its parent's position, for drawing.</summary>
	public Vector2[] GetOrbitPolyline(int index, int segments = 128)
	{
		if (!ValidIndex(index) || _ephemeris.Bodies[index].Parent < 0)
			return System.Array.Empty<Vector2>();
		BodyDef body = _ephemeris.Bodies[index];
		double mu = _ephemeris.ParentMu(index);
		double period = body.Orbit.Period(mu);
		var points = new Vector2[segments + 1];
		for (int i = 0; i <= segments; i++)
		{
			// Sample by eccentric anomaly so the ellipse is evenly covered.
			double e = body.Orbit.Eccentricity;
			double eccentricAnomaly = 2.0 * Math.PI * i / segments;
			double meanAnomaly = eccentricAnomaly - e * Math.Sin(eccentricAnomaly);
			double t = (meanAnomaly - body.Orbit.MeanAnomalyAtEpoch) / (2.0 * Math.PI) * period;
			body.Orbit.StateAt(t, mu, out Vector2D p, out _);
			points[i] = p.ToVector2();
		}
		return points;
	}

	private bool ValidIndex(int index) => _ephemeris != null && index >= 0 && index < _ephemeris.Count;

	#endregion

	#region Time warp

	public void SetTimeWarpIndex(int index)
	{
		if (WarpLevels.Length == 0)
			return;
		int max = WarpLevels.Length - 1;
		if (_warpCapIndex >= 0)
			max = Math.Min(max, _warpCapIndex);
		index = Math.Clamp(index, 0, max);
		bool changed = index != _warpIndex;
		_warpIndex = index;
		int warp = WarpLevels[index];
		// Scale time and tick rate together: each physics step stays PhysicsDt long, so predictions stay exact.
		Engine.TimeScale = _baseTimeScale * warp;
		Engine.PhysicsTicksPerSecond = _baseTicks * warp;
		Engine.MaxPhysicsStepsPerFrame = Math.Max(_baseMaxSteps, warp * 2);
		if (changed)
			EmitSignal(SignalName.TimeWarpChanged, warp);
	}

	public void IncreaseTimeWarp() => SetTimeWarpIndex(_warpIndex + 1);

	public void DecreaseTimeWarp() => SetTimeWarpIndex(_warpIndex - 1);

	/// <summary>
	/// Highest warp index at which <paramref name="simSeconds"/> of simulation time still lasts at least
	/// <paramref name="realSeconds"/> of real time (0 if none).
	/// </summary>
	public int WarpIndexForLead(double simSeconds, double realSeconds)
	{
		int best = 0;
		for (int i = 0; i < WarpLevels.Length; i++)
			if (WarpLevels[i] * realSeconds <= simSeconds)
				best = i;
		return best;
	}

	#endregion

	#region Solvers

	/// <summary>
	/// Synchronous trajectory prediction from a ship's current state (see <see cref="StateTime"/>).
	/// Options: max_time (s, 600), sample_every (ticks, 10), stop_after_orbits (1.0), watch_body (-1),
	/// watch_from/watch_until (s), burns (Array of {time, delta_v} or maneuver nodes {time, prograde, radial}, plus optional
	/// thrust/mass/exhaust_velocity for finite burns).
	/// </summary>
	public TrajectoryPrediction Predict(Vector2 position, Vector2 velocity, Dictionary options)
	{
		if (_ephemeris == null)
			return null;
		PredictionSettings settings = ParsePredictionOptions(options);
		return TrajectoryPrediction.Create(
			TrajectoryPredictor.Predict(_ephemeris, position, velocity, StateTime, settings), _ephemeris);
	}

	/// <summary>Same as <see cref="Predict"/> on a worker thread. The job's Completed signal delivers a TrajectoryPrediction.</summary>
	public OrbitalJob PredictAsync(Vector2 position, Vector2 velocity, Dictionary options)
	{
		if (_ephemeris == null)
			return null;
		Ephemeris eph = _ephemeris;
		double t0 = StateTime;
		PredictionSettings settings = ParsePredictionOptions(options);
		Vector2D pos = position, vel = velocity;
		return RunJob(() => TrajectoryPredictor.Predict(eph, pos, vel, t0, settings),
			result => TrajectoryPrediction.Create(result, eph));
	}

	/// <summary>
	/// Plans a transfer to body <paramref name="target"/> on a worker thread. The job's Completed signal delivers a plan
	/// Dictionary (see <see cref="PlanToDictionary"/>). Options: capture (true), arrival_periapsis (auto),
	/// allow_gravity_assist (true), capture_apoapsis (0 = circular capture orbit), assist_advantage (0.9: an assist must cost under 90% of the direct route),
	/// min_lead_time (8 s), max_search_window (auto), refine (true), and the ship's
	/// engine {thrust, mass, exhaust_velocity} so burns are simulated as finite burns.
	/// </summary>
	public OrbitalJob PlanTransferAsync(Vector2 position, Vector2 velocity, int target, Dictionary options)
	{
		if (_ephemeris == null)
			return null;
		Ephemeris eph = _ephemeris;
		TransferRequest request = BuildTransferRequest(position, velocity, target, options);
		return RunJob(() => TransferPlanner.Plan(eph, request), plan => PlanToDictionary(plan));
	}

	/// <summary>
	/// Navigation computer: plans a transfer to <paramref name="target"/> and converts it into maneuver nodes in the
	/// orbital frame (same options as <see cref="PlanTransferAsync"/>). The job's Completed signal delivers
	/// {valid, message, route, nodes: [{time, prograde, radial, kind}], encounters: [{body, time, periapsis, capture,
	/// is_final, flyby_prograde_delta_v}], total_delta_v, arrival_body, reaches_target, assist_body, arrival_periapsis}.
	/// </summary>
	public OrbitalJob PlotCourseAsync(Vector2 position, Vector2 velocity, int target, Dictionary options)
	{
		if (_ephemeris == null)
			return null;
		Ephemeris eph = _ephemeris;
		TransferRequest request = BuildTransferRequest(position, velocity, target, options);
		return RunJob(() => CoursePlotter.Plot(eph, request), plot => CourseToDictionary(plot));
	}

	/// <summary>
	/// Course maintenance: re-plots the remaining <paramref name="encounters"/> of a plotted course (as returned by
	/// <see cref="PlotCourseAsync"/>) from the ship's current state, adding a correction node when needed and re-solving
	/// the periapsis burns. Same result format as <see cref="PlotCourseAsync"/>; options as for planning
	/// (min_lead_time and the engine).
	/// </summary>
	public OrbitalJob ContinueCourseAsync(Vector2 position, Vector2 velocity, int target, Array<Dictionary> encounters,
		Dictionary options)
	{
		if (_ephemeris == null)
			return null;
		Ephemeris eph = _ephemeris;
		TransferRequest request = BuildTransferRequest(position, velocity, target, options);
		var remaining = new List<CourseEncounter>();
		foreach (Dictionary e in encounters)
		{
			remaining.Add(new CourseEncounter
			{
				Body = e["body"].AsInt32(),
				Time = e["time"].AsDouble(),
				Periapsis = e["periapsis"].AsDouble(),
				Capture = e["capture"].AsBool(),
				CaptureApoapsis = e.TryGetValue("capture_apoapsis", out Variant ca) ? ca.AsDouble() : 0.0,
				IsFinal = e["is_final"].AsBool(),
				FlybyProgradeDeltaV = e.TryGetValue("flyby_prograde_delta_v", out Variant f) ? f.AsDouble() : 0.0,
			});
		}
		return RunJob(() => CoursePlotter.Continue(eph, request, remaining), plot => CourseToDictionary(plot));
	}

	private static Dictionary CourseToDictionary(CoursePlot plot)
	{
		var nodes = new Array<Dictionary>();
		foreach (PlottedNode n in plot.Nodes)
		{
			nodes.Add(new Dictionary
			{
				{ "time", n.Time }, { "prograde", n.Prograde }, { "radial", n.Radial }, { "kind", n.Kind },
			});
		}
		var encounters = new Array<Dictionary>();
		foreach (CourseEncounter e in plot.Encounters)
		{
			encounters.Add(new Dictionary
			{
				{ "body", e.Body }, { "time", e.Time }, { "periapsis", e.Periapsis }, { "capture", e.Capture },
				{ "capture_apoapsis", e.CaptureApoapsis },
				{ "is_final", e.IsFinal }, { "flyby_prograde_delta_v", e.FlybyProgradeDeltaV },
			});
		}
		return new Dictionary
		{
			{ "valid", plot.Valid },
			{ "message", plot.Message },
			{ "route", plot.Route },
			{ "nodes", nodes },
			{ "encounters", encounters },
			{ "total_delta_v", plot.TotalDeltaV },
			{ "arrival_body", plot.ArrivalBody },
			{ "reaches_target", plot.ReachesTarget },
			{ "assist_body", plot.AssistBody },
			{ "arrival_periapsis", plot.ArrivalPeriapsis },
		};
	}

	/// <summary>
	/// Targeting solver for course corrections: finds the delta-v of a burn at <paramref name="burnTime"/> that brings the
	/// ship to signed periapsis <paramref name="periapsis"/> at <paramref name="body"/> around
	/// <paramref name="expectedTime"/> (also enforced when <paramref name="constrainTime"/>), using at most
	/// <paramref name="maxDeltaV"/> (0 = unlimited). The job's Completed signal
	/// delivers {converged, has_encounter, delta_v, periapsis, encounter_time, miss, initial_miss, iterations}.
	/// </summary>
	public OrbitalJob RefineBurnAsync(Vector2 position, Vector2 velocity, double burnTime, Vector2 deltaVGuess, int body,
		double periapsis, double expectedTime, bool constrainTime, double horizonEnd, double maxDeltaV, Dictionary engine)
	{
		if (!ValidIndex(body))
			return null;
		Ephemeris eph = _ephemeris;
		double t0 = StateTime, dt = PhysicsDt;
		Vector2D pos = position, vel = velocity, guess = deltaVGuess;
		EngineModel engineModel = ParseEngine(engine);
		return RunJob(() => TransferPlanner.Refine(eph, pos, vel, t0, dt, burnTime, guess, body, periapsis, expectedTime,
				constrainTime, horizonEnd, 16, maxDeltaV > 0.0 ? maxDeltaV : double.PositiveInfinity, engineModel),
			r => new Dictionary
			{
				{ "converged", r.Converged },
				{ "has_encounter", r.HasEncounter },
				{ "delta_v", r.DeltaV.ToVector2() },
				{ "periapsis", r.Periapsis },
				{ "encounter_time", r.EncounterTime },
				{ "miss", r.Miss },
				{ "initial_miss", r.InitialMiss },
				{ "iterations", r.Iterations },
			});
	}

	/// <summary>
	/// {valid, message, estimated_delta_v, target_body, central_body, departure_body, arrival_body, assist_body,
	/// refined, refine_miss, burns: [{kind, time, delta_v, prograde_delta_v, body, reference_angle, local_delta_v}],
	/// encounters: [{body, time, periapsis, capture, is_final}]}
	/// </summary>
	public static Dictionary PlanToDictionary(TransferPlan plan)
	{
		var burns = new Array<Dictionary>();
		foreach (PlannedBurn b in plan.Burns)
		{
			burns.Add(new Dictionary
			{
				{ "kind", (int)b.Kind },
				{ "time", b.Time },
				{ "delta_v", b.DeltaV.ToVector2() },
				{ "prograde_delta_v", b.ProgradeDeltaV },
				{ "body", b.Body },
				{ "reference_angle", b.ReferenceAngle },
				{ "local_delta_v", b.LocalDeltaV.ToVector2() },
			});
		}
		var encounters = new Array<Dictionary>();
		foreach (PlannedEncounter e in plan.Encounters)
		{
			encounters.Add(new Dictionary
			{
				{ "body", e.Body },
				{ "time", e.Time },
				{ "periapsis", e.Periapsis },
				{ "capture", e.Capture },
				{ "is_final", e.IsFinal },
			});
		}
		return new Dictionary
		{
			{ "valid", plan.Valid },
			{ "message", plan.Message },
			{ "estimated_delta_v", plan.EstimatedDeltaV },
			{ "target_body", plan.TargetBody },
			{ "central_body", plan.CentralBody },
			{ "departure_body", plan.DepartureBody },
			{ "arrival_body", plan.ArrivalBody },
			{ "assist_body", plan.AssistBody },
			{ "refined", plan.Refined },
			{ "refine_miss", plan.RefineMiss },
			{ "burns", burns },
			{ "encounters", encounters },
		};
	}

	private TransferRequest BuildTransferRequest(Vector2 position, Vector2 velocity, int target, Dictionary options)
	{
		return new TransferRequest
		{
			Position = position,
			Velocity = velocity,
			Time = StateTime,
			Dt = PhysicsDt,
			Target = target,
			Capture = options.TryGetValue("capture", out Variant capture) ? capture.AsBool() : true,
			ArrivalPeriapsis = options.TryGetValue("arrival_periapsis", out Variant rp) ? rp.AsDouble() : 0.0,
			CaptureApoapsis = options.TryGetValue("capture_apoapsis", out Variant ra) ? ra.AsDouble() : 0.0,
			MaxCorrectionDeltaV = options.TryGetValue("max_correction_delta_v", out Variant mc) ? mc.AsDouble() : 0.0,
			AllowGravityAssist = options.TryGetValue("allow_gravity_assist", out Variant ga) ? ga.AsBool() : true,
			AssistAdvantage = options.TryGetValue("assist_advantage", out Variant adv) ? adv.AsDouble() : 0.9,
			MinLeadTime = options.TryGetValue("min_lead_time", out Variant lead) ? lead.AsDouble() : 8.0,
			MaxSearchWindow = options.TryGetValue("max_search_window", out Variant window) ? window.AsDouble() : 0.0,
			Refine = options.TryGetValue("refine", out Variant refine) ? refine.AsBool() : true,
			Engine = ParseEngine(options),
		};
	}

	/// <summary>Reads {thrust, mass, exhaust_velocity}; missing values give impulsive burns.</summary>
	private static EngineModel ParseEngine(Dictionary options)
	{
		if (options == null)
			return default;
		double thrust = options.TryGetValue("thrust", out Variant t) ? t.AsDouble() : 0.0;
		double mass = options.TryGetValue("mass", out Variant m) ? m.AsDouble() : 0.0;
		double exhaust = options.TryGetValue("exhaust_velocity", out Variant e) ? e.AsDouble() : 0.0;
		return new EngineModel(thrust, mass, exhaust);
	}

	private PredictionSettings ParsePredictionOptions(Dictionary options)
	{
		double dt = PhysicsDt;
		double maxTime = options.TryGetValue("max_time", out Variant mt) ? mt.AsDouble() : 600.0;
		var settings = new PredictionSettings
		{
			Dt = dt,
			MaxSteps = Math.Max(1, (int)Math.Ceiling(maxTime / dt)),
			SampleEvery = Math.Max(1, options.TryGetValue("sample_every", out Variant se) ? se.AsInt32() : 10),
			StopAfterOrbits = options.TryGetValue("stop_after_orbits", out Variant so) ? so.AsDouble() : 1.0,
			WatchBody = options.TryGetValue("watch_body", out Variant wb) ? wb.AsInt32() : -1,
			WatchFrom = options.TryGetValue("watch_from", out Variant wf) ? wf.AsDouble() : double.NegativeInfinity,
			WatchUntil = options.TryGetValue("watch_until", out Variant wu) ? wu.AsDouble() : double.PositiveInfinity,
		};
		if (!ValidIndex(settings.WatchBody))
			settings.WatchBody = -1;
		if (options.TryGetValue("burns", out Variant burns))
		{
			foreach (Variant item in burns.AsGodotArray())
			{
				Dictionary burn = item.AsGodotDictionary();
				ImpulseBurn planned;
				if (burn.ContainsKey("prograde") || burn.ContainsKey("radial"))
				{
					// Orbital-frame burn (maneuver node): delta_v = (prograde, radial-out) at burn start.
					var local = new Vector2D(burn.TryGetValue("prograde", out Variant p) ? p.AsDouble() : 0.0,
						burn.TryGetValue("radial", out Variant r) ? r.AsDouble() : 0.0);
					planned = ParseEngine(burn).Make(burn["time"].AsDouble(), local);
					planned.OrbitalFrame = true;
				}
				else
				{
					planned = ParseEngine(burn).Make(burn["time"].AsDouble(), burn["delta_v"].AsVector2());
				}
				settings.Burns.Add(planned);
			}
		}
		return settings;
	}

	/// <summary>
	/// Runs <paramref name="work"/> on the thread pool; the converted result is emitted from the job on the main thread.
	/// (Results go through a signal because GDScript lambdas cannot be passed into C# as Callables.)
	/// </summary>
	private static OrbitalJob RunJob<T>(Func<T> work, Func<T, Variant> convert)
	{
		var job = new OrbitalJob();
		Task.Run(() =>
		{
			T result;
			try
			{
				result = work();
			}
			catch (Exception e)
			{
				Callable.From(() => GD.PushError($"Orbital solver failed: {e}")).CallDeferred();
				return;
			}
			Callable.From(() => job.Complete(convert(result))).CallDeferred();
		});
		return job;
	}

	#endregion
}
