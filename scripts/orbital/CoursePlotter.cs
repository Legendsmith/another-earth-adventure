using System;
using System.Collections.Generic;

namespace AnotherEarth.Orbital;

/// <summary>A maneuver node in the orbital frame: (prograde, radial-out) delta-v relative to the dominant body at burn start.</summary>
public sealed class PlottedNode
{
	public double Time;
	public double Prograde;
	public double Radial;
	public string Kind = "";
}

/// <summary>One encounter of a course and the periapsis burn it needs, kept so the course can be maintained in flight.</summary>
public sealed class CourseEncounter
{
	public int Body;
	public double Time;
	/// <summary>Target periapsis, signed by pass direction.</summary>
	public double Periapsis;
	public bool Capture;
	/// <summary>Apoapsis radius of the capture orbit; 0 or below the periapsis = circular.</summary>
	public double CaptureApoapsis;
	public bool IsFinal;
	/// <summary>Flyby burn along the relative velocity at periapsis (gravity assists only).</summary>
	public double FlybyProgradeDeltaV;
}

public sealed class CoursePlot
{
	public bool Valid;
	public string Message = "";
	public readonly List<PlottedNode> Nodes = new();
	/// <summary>Encounters of the plotted course; pass them to <see cref="CoursePlotter.Continue"/> to maintain it.</summary>
	public readonly List<CourseEncounter> Encounters = new();
	public double TotalDeltaV;
	public int ArrivalBody = -1;
	/// <summary>False when the course stops at an intermediate body (e.g. the parent of a moon target).</summary>
	public bool ReachesTarget;
	public int AssistBody = -1;
	public string Route = "";
	/// <summary>Periapsis distance at the final encounter of the plotted course.</summary>
	public double ArrivalPeriapsis = double.NaN;
}

/// <summary>
/// Navigation computer: turns a <see cref="TransferPlan"/> into player maneuver nodes, and keeps the course on target.
/// <para>Each burn is converted to the orbital frame using the ship's predicted state at the moment that burn starts,
/// with all earlier nodes applied. Orbital-frame finite burns are simulated by the predictor exactly as the ship flies
/// them, so the nodes reproduce the planned trajectory. Periapsis burns (gravity assists and capture) are resolved
/// from the predicted encounter.</para>
/// <para>Interplanetary courses are very sensitive to the departure burn, so a one-shot plot is not enough in
/// practice: <see cref="Continue"/> re-plots the remaining encounters from the ship's actual state in flight, adding
/// a correction node when the predicted periapsis is off and re-solving the periapsis burns.</para>
/// </summary>
public static class CoursePlotter
{
	public static CoursePlot Plot(Ephemeris eph, TransferRequest req)
	{
		var plot = new CoursePlot();
		TransferPlan plan = TransferPlanner.Plan(eph, req);
		plot.Route = plan.Message;
		plot.AssistBody = plan.AssistBody;
		plot.ArrivalBody = plan.ArrivalBody;
		if (!plan.Valid)
		{
			plot.Message = plan.Message;
			return plot;
		}

		var sim = new CourseSimulation(eph, req);
		int nextBurn = 0;
		if (plan.Burns.Count > 0 && plan.Burns[0].Kind is BurnKind.Impulse or BurnKind.Ejection)
		{
			sim.AddInertialBurn(plan.Burns[0].Time, plan.Burns[0].DeltaV, "departure");
			nextBurn = 1;
		}

		var encounters = new List<CourseEncounter>();
		foreach (PlannedEncounter e in plan.Encounters)
		{
			var encounter = new CourseEncounter
			{
				Body = e.Body, Time = e.Time, Periapsis = e.Periapsis, Capture = e.Capture, IsFinal = e.IsFinal,
				// Intermediate stops (the parent of a moon target) always use a circular orbit to depart from.
				CaptureApoapsis = e.IsFinal ? req.CaptureApoapsis : 0.0,
			};
			if (nextBurn < plan.Burns.Count && plan.Burns[nextBurn].Body == e.Body)
			{
				if (plan.Burns[nextBurn].Kind == BurnKind.FlybyPeriapsis)
					encounter.FlybyProgradeDeltaV = plan.Burns[nextBurn].ProgradeDeltaV;
				nextBurn++;
			}
			encounters.Add(encounter);
		}

		// On the plotted course a correction is only placed once the ship is clear of the departure body.
		double[] fractions = plan.Message == "already_in_sphere" ? null : new[] { 0.25, 0.4, 0.55, 0.7 };
		// Already at the destination (e.g. parking after an intercept): the capture burn may come at once, but no sooner
		// than the lead time; if the ship is past periapsis, it circularises where it is.
		if (plan.Message == "already_in_sphere")
			sim.SetEarliestBurn(req.Time + req.MinLeadTime);
		FollowEncounters(eph, req, sim, encounters, fractions, plot);
		if (plot.Message.Length == 0)
			plot.Message = !plot.Valid ? "no_burns_needed" : plot.ReachesTarget ? plan.Message : "partial_course";
		return plot;
	}

	/// <summary>
	/// Course maintenance: re-plots the remaining <paramref name="encounters"/> from the ship's current state (in
	/// <paramref name="req"/>). Adds a correction node soon after the request if the predicted periapsis is off, then
	/// re-solves the periapsis burns.
	/// </summary>
	public static CoursePlot Continue(Ephemeris eph, TransferRequest req, List<CourseEncounter> encounters)
	{
		var plot = new CoursePlot { Route = "maintenance" };
		if (encounters.Count == 0)
		{
			plot.Message = "no_encounters";
			return plot;
		}
		var sim = new CourseSimulation(eph, req);
		sim.SetEarliestBurn(req.Time + req.MinLeadTime);
		FollowEncounters(eph, req, sim, encounters, new[] { 0.0, 0.1, 0.25 }, plot);
		if (plot.Message.Length == 0)
			plot.Message = plot.Valid ? "maintained" : "no_burns_needed";
		return plot;
	}

	private static void FollowEncounters(Ephemeris eph, TransferRequest req, CourseSimulation sim,
		List<CourseEncounter> encounters, double[] correctionFractions, CoursePlot plot)
	{
		foreach (CourseEncounter encounter in encounters)
		{
			if (correctionFractions != null)
				sim.TryAddCorrection(encounter, correctionFractions);

			PredictionResult pass = sim.PredictEncounter(encounter);
			// Only the encounter pass itself matters: without its burn the ship may well hit the body on a later orbit.
			bool impacts = pass.HasClosestApproach && pass.ClosestApproachDistance <= eph.Bodies[encounter.Body].Radius;
			if (!pass.HasClosestApproach || impacts)
			{
				plot.Message = impacts ? "course_impacts" : "no_encounter";
				return;
			}

			double tca = Math.Max(pass.ClosestApproachTime, sim.LastBurnEnd + req.Dt);
			Vector2D relPos = pass.ClosestApproachRelPosition;
			Vector2D relVel = pass.ClosestApproachRelVelocity;
			if (encounter.Capture && !pass.ClosestApproachIsMinimum
				&& sim.NextPeriapsis(encounter.Body, out double tp, out Vector2D pPos, out Vector2D pVel))
			{
				// Already past periapsis but bound (e.g. parking after an intercept): capture at the next periapsis
				// rather than wherever the ship is now, out near the edge of the sphere.
				tca = tp;
				relPos = pPos;
				relVel = pVel;
			}
			encounter.Time = tca;
			plot.ArrivalBody = encounter.Body;
			plot.ArrivalPeriapsis = relPos.Length;
			plot.Encounters.Add(encounter);

			if (encounter.Capture)
			{
				// Tangential speed for the capture orbit at this radius: circular, or the periapsis speed of an ellipse.
				double spin = relPos.Cross(relVel) >= 0.0 ? 1.0 : -1.0;
				double r = relPos.Length;
				double mu = eph.Bodies[encounter.Body].Mu;
				double apoapsis = Math.Min(encounter.CaptureApoapsis, 0.95 * Math.Min(eph.Bodies[encounter.Body].SphereOfInfluence,
					eph.Bodies[encounter.Body].GravityRadius));
				double speed = apoapsis > r ? Math.Sqrt(mu * (2.0 / r - 2.0 / (r + apoapsis))) : Math.Sqrt(mu / r);
				Vector2D target = relPos.Normalized().Perpendicular * spin * speed;
				sim.AddInertialBurn(tca, target - relVel, "capture");
				if (!encounter.IsFinal)
					break; // Moon target: the next hop is plotted from orbit around this body.
			}
			else if (Math.Abs(encounter.FlybyProgradeDeltaV) > 0.05)
			{
				sim.AddInertialBurn(tca, relVel.Normalized() * encounter.FlybyProgradeDeltaV, "flyby");
			}
		}

		plot.ReachesTarget = plot.ArrivalBody == req.Target;
		plot.Nodes.AddRange(sim.Nodes);
		foreach (PlottedNode node in plot.Nodes)
			plot.TotalDeltaV += Math.Sqrt(node.Prograde * node.Prograde + node.Radial * node.Radial);
		plot.Valid = plot.Nodes.Count > 0;
	}

	/// <summary>The ship's course with the nodes plotted so far, re-simulated from the request state.</summary>
	private sealed class CourseSimulation
	{
		public readonly List<PlottedNode> Nodes = new();
		public double LastBurnEnd;

		private readonly Ephemeris _eph;
		private readonly TransferRequest _req;
		private readonly List<ImpulseBurn> _burns = new();
		private double _mass;

		public CourseSimulation(Ephemeris eph, TransferRequest req)
		{
			_eph = eph;
			_req = req;
			_mass = req.Engine.Mass;
			LastBurnEnd = req.Time;
		}

		/// <summary>No burn (including corrections) may start before <paramref name="time"/>.</summary>
		public void SetEarliestBurn(double time) => LastBurnEnd = Math.Max(LastBurnEnd, time);

		private EngineModel Engine => new(_req.Engine.Thrust, _mass, _req.Engine.ExhaustVelocity);

		private PredictionResult Run(int steps, int watchBody = -1, double watchFrom = double.NegativeInfinity)
		{
			return TrajectoryPredictor.Predict(_eph, _req.Position, _req.Velocity, _req.Time, new PredictionSettings
			{
				Dt = _req.Dt,
				MaxSteps = Math.Max(0, steps),
				RecordSamples = false,
				RecordApsides = false,
				StopOnCollision = watchBody >= 0,
				WatchBody = watchBody,
				WatchFrom = watchFrom,
				Burns = new List<ImpulseBurn>(_burns),
			});
		}

		/// <summary>State at the first physics tick at or after <paramref name="time"/>, before any burn starting then.</summary>
		private PredictionResult StateAt(double time) =>
			Run((int)Math.Ceiling((time - _req.Time) / _req.Dt - 1e-6));

		/// <summary>
		/// Adds a burn given as an inertial delta-v centred on <paramref name="time"/>, converted to the orbital frame
		/// at the state where the finite burn starts (the predictor and the ship both fix the direction there).
		/// </summary>
		public void AddInertialBurn(double time, Vector2D deltaV, string kind)
		{
			ImpulseBurn inertial = Engine.Make(time, deltaV);
			PredictionResult start = StateAt(Math.Max(inertial.StartTime, _req.Time));
			var bodyPos = new Vector2D[_eph.Count];
			var bodyVel = new Vector2D[_eph.Count];
			_eph.ComputeStates(start.FinalTime, bodyPos, bodyVel);
			int dominant = _eph.FindDominant(start.FinalPosition, bodyPos);
			Vector2D relPos = dominant >= 0 ? start.FinalPosition - bodyPos[dominant] : start.FinalPosition;
			Vector2D relVel = dominant >= 0 ? start.FinalVelocity - bodyVel[dominant] : start.FinalVelocity;
			ImpulseBurn.OrbitalAxes(relPos, relVel, out Vector2D prograde, out Vector2D radialOut);
			var local = new Vector2D(deltaV.Dot(prograde), deltaV.Dot(radialOut));

			ImpulseBurn node = Engine.Make(time, local);
			node.OrbitalFrame = true;
			_burns.Add(node);
			Nodes.Add(new PlottedNode { Time = time, Prograde = local.X, Radial = local.Y, Kind = kind });
			LastBurnEnd = time + 0.5 * inertial.Duration;
			if (_req.Engine.ExhaustVelocity > 0.0)
				_mass /= Math.Exp(deltaV.Length / _req.Engine.ExhaustVelocity);
		}

		/// <summary>Next periapsis around <paramref name="body"/> after the last burn (within a few thousand seconds), relative to it.</summary>
		public bool NextPeriapsis(int body, out double time, out Vector2D relPos, out Vector2D relVel)
		{
			time = 0.0;
			relPos = relVel = Vector2D.Zero;
			PredictionResult r = TrajectoryPredictor.Predict(_eph, _req.Position, _req.Velocity, _req.Time, new PredictionSettings
			{
				Dt = _req.Dt,
				MaxSteps = (int)Math.Ceiling((LastBurnEnd + 4000.0 - _req.Time) / _req.Dt),
				RecordSamples = false,
				RecordApsides = true,
				StopOnCollision = true,
				Burns = new List<ImpulseBurn>(_burns),
			});
			foreach (PredictionEvent e in r.Events)
			{
				if (e.Type != PredictionEventType.Periapsis || e.Body != body || e.Time < LastBurnEnd)
					continue;
				_eph.GetState(body, e.Time, out Vector2D bodyPos, out Vector2D bodyVel);
				time = e.Time;
				relPos = e.Position - bodyPos;
				relVel = e.Velocity - bodyVel;
				return true;
			}
			return false;
		}

		/// <summary>Predicts the course so far through the encounter, tracking the first pass after the last burn.</summary>
		public PredictionResult PredictEncounter(CourseEncounter encounter)
		{
			double leg = Math.Max(encounter.Time - LastBurnEnd, 60.0);
			double horizon = Math.Max(encounter.Time, LastBurnEnd) + Math.Max(0.5 * leg, 600.0);
			return Run((int)Math.Ceiling((horizon - _req.Time) / _req.Dt), encounter.Body, LastBurnEnd);
		}

		/// <summary>
		/// Correction for the leg to <paramref name="encounter"/>, at the first of <paramref name="fractions"/> of the leg
		/// where the ship is on route (the target or one of its ancestors dominates). Solved with the n-body targeter
		/// and only kept if it meaningfully improves the periapsis.
		/// </summary>
		public void TryAddCorrection(CourseEncounter encounter, double[] fractions)
		{
			PredictionResult check = PredictEncounter(encounter);
			if (!check.HasClosestApproach)
				return;
			BodyDef target = _eph.Bodies[encounter.Body];
			double tolerance = Math.Max(0.1 * Math.Abs(encounter.Periapsis), 0.25 * target.Radius);
			bool impacts = check.ClosestApproachDistance <= target.Radius;
			if (!impacts && Math.Abs(check.ClosestApproachSigned - encounter.Periapsis) <= tolerance)
				return;

			double horizon = check.FinalTime;
			foreach (double fraction in fractions)
			{
				double burnTime = LastBurnEnd + fraction * (check.ClosestApproachTime - LastBurnEnd) + 5.0;
				PredictionResult state = StateAt(burnTime - 5.0);
				var bodyPos = new Vector2D[_eph.Count];
				var bodyVel = new Vector2D[_eph.Count];
				_eph.ComputeStates(state.FinalTime, bodyPos, bodyVel);
				int dominant = _eph.FindDominant(state.FinalPosition, bodyPos);
				if (dominant != encounter.Body && !_eph.IsAncestorOf(dominant, encounter.Body))
					continue;
				RefineResult r = TransferPlanner.Refine(_eph, state.FinalPosition, state.FinalVelocity, state.FinalTime,
					_req.Dt, state.FinalTime + 5.0, Vector2D.Zero, encounter.Body, encounter.Periapsis, encounter.Time,
					false, horizon, 16, _req.MaxCorrectionDeltaV > 0.0 ? _req.MaxCorrectionDeltaV : double.PositiveInfinity, Engine);
				if (r.HasEncounter && (r.Converged || r.Miss < 0.5 * r.InitialMiss) && r.DeltaV.Length > 0.05)
					AddInertialBurn(r.BurnTime, r.DeltaV, "correction");
				return;
			}
		}
	}
}
