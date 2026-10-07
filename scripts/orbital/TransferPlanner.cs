using System;
using System.Collections.Generic;

namespace AnotherEarth.Orbital;

public enum BurnKind
{
	/// <summary>Fixed inertial delta-v at a fixed time.</summary>
	Impulse = 0,
	/// <summary>Prograde escape burn from a parking orbit (Oberth effect); executed like an impulse.</summary>
	Ejection = 1,
	/// <summary>Powered gravity assist: prograde/retrograde burn at flyby periapsis, resolved when the ship gets there.</summary>
	FlybyPeriapsis = 2,
	/// <summary>Retrograde burn at periapsis that circularises the orbit around the encountered body.</summary>
	CapturePeriapsis = 3,
	/// <summary>Mid-course correction produced by the targeting solver.</summary>
	Correction = 4,
}

public sealed class PlannedBurn
{
	public BurnKind Kind;
	public double Time;
	/// <summary>Inertial delta-v for Impulse/Ejection/Correction burns.</summary>
	public Vector2D DeltaV;
	/// <summary>Planned delta-v along the relative velocity for periapsis burns (negative = retrograde).</summary>
	public double ProgradeDeltaV;
	public int Body = -1;
	/// <summary>
	/// Ejection burns only: angle of the burn point around <see cref="Body"/>, and the delta-v split into
	/// (radial, along-track) components. Executing by orbital position rather than clock time is robust to the
	/// small phase drift that builds up over many parking orbits.
	/// </summary>
	public double ReferenceAngle;
	public Vector2D LocalDeltaV;
}

public sealed class PlannedEncounter
{
	public int Body;
	public double Time;
	/// <summary>Target periapsis signed by pass direction (positive = positive angular momentum about the body).</summary>
	public double Periapsis;
	public bool Capture;
	/// <summary>False when the encounter is an intermediate stop (gravity assist, or the parent of a moon target).</summary>
	public bool IsFinal;
}

public sealed class TransferPlan
{
	public bool Valid;
	public string Message = "";
	public readonly List<PlannedBurn> Burns = new();
	public readonly List<PlannedEncounter> Encounters = new();
	public double EstimatedDeltaV;
	public int TargetBody = -1;
	public int CentralBody = -1;
	public int DepartureBody = -1;
	public int ArrivalBody = -1;
	public int AssistBody = -1;
	public bool Refined;
	/// <summary>Remaining periapsis error after the n-body targeting pass, in px.</summary>
	public double RefineMiss = double.PositiveInfinity;
}

public sealed class TransferRequest
{
	public Vector2D Position;
	public Vector2D Velocity;
	public double Time;
	public double Dt = 1.0 / 60.0;
	public int Target = -1;
	public bool Capture = true;
	/// <summary>Desired periapsis radius at the target; 0 picks a default from the body's size.</summary>
	public double ArrivalPeriapsis;
	/// <summary>Capture into an ellipse with this apoapsis radius at the target (0 = circular orbit).</summary>
	public double CaptureApoapsis;
	public bool AllowGravityAssist = true;
	/// <summary>Earliest a burn may be scheduled after the request time (time to turn the ship around).</summary>
	public double MinLeadTime = 8.0;
	/// <summary>How far ahead to search for departure windows; 0 = one synodic period (clamped).</summary>
	public double MaxSearchWindow;
	public int DepartureSamples = 32;
	public int TimeOfFlightSamples = 24;
	public int AssistSamples = 12;
	/// <summary>A gravity assist route is only chosen if it costs less than this fraction of the best direct route.</summary>
	public double AssistAdvantage = 0.9;
	public bool Refine = true;
	/// <summary>Largest course correction the navigation computer may add (0 = unlimited).</summary>
	public double MaxCorrectionDeltaV;
	/// <summary>Ship engine, so the planner simulates finite burns (default: impulsive).</summary>
	public EngineModel Engine;
	/// <summary>Hull radius of the ship (see <see cref="PredictionSettings.ShipRadius"/>).</summary>
	public double ShipRadius;
}

public sealed class RefineResult
{
	public bool Converged;
	public bool HasEncounter;
	public double BurnTime;
	public Vector2D DeltaV;
	public double Periapsis;
	public double EncounterTime;
	public double Miss = double.PositiveInfinity;
	/// <summary>Miss of the starting guess, to judge partial improvements.</summary>
	public double InitialMiss = double.PositiveInfinity;
	public int Iterations;
}

/// <summary>
/// Plans interplanetary transfers for NPCs (and the player autopilot).
/// <para>1. Patched-conic search: Lambert arcs around the common central body over a grid of departure times and
/// flight times, costing ejection from a parking orbit (Oberth burn at periapsis) and capture at arrival.</para>
/// <para>2. Gravity assist search: two-leg Lambert routes via every sibling body, checking the flyby can actually
/// turn the hyperbolic excess velocity without hitting the planet, and costing any powered-flyby burn.</para>
/// <para>3. Targeting: the first burn is refined with Newton iterations over the full n-body prediction so
/// that the encounter periapsis (and flyby timing) is hit in the real physics simulation.</para>
/// </summary>
public static class TransferPlanner
{
	private const int MaxTableSteps = 150_000;

	/// <summary>Optional diagnostics sink for the targeting solver.</summary>
	public static Action<string> Trace;

	private struct DepartureState
	{
		public int SampleIndex;
		public double Time;
		public Vector2D R1;
		public Vector2D VHave;
		public Vector2D ShipRel;
		public Vector2D ShipRelVel;
	}

	private struct Candidate
	{
		public double Cost;
		public double DepartureCost;
		public double FlybyCost;
		public double ArrivalCost;
		public DepartureState Departure;
		public Vector2D V1;
		public double FlybyTime;
		public double FlybyPeriapsisSigned;
		public double FlybyProgradeDv;
		public double ArrivalTime;
	}

	public static double HohmannTime(double r1, double r2, double mu)
	{
		double a = 0.5 * (r1 + r2);
		return Math.PI * Math.Sqrt(a * a * a / mu);
	}

	public static double DefaultPeriapsis(BodyDef body)
	{
		// Low enough that the parent's tides cannot pump the orbit into the surface (they scale with r^3).
		double preferred = Math.Min(body.Radius * 2.0, body.SphereOfInfluence * 0.3);
		return Math.Max(preferred, body.Radius * 1.3);
	}

	/// <summary>
	/// Speed at <paramref name="radius"/> inside a body's gravity well for a ship crossing the well's edge at
	/// <paramref name="edgeSpeed"/>. Gravity areas stop at <see cref="BodyDef.GravityRadius"/>, so the potential is
	/// -mu/r + mu/R inside and flat outside: this is the exact patched-conic relation for the game's physics.
	/// </summary>
	public static double SpeedAtRadius(BodyDef body, double edgeSpeed, double radius)
	{
		double well = 2.0 * body.Mu / radius - 2.0 * body.Mu / body.GravityRadius;
		return Math.Sqrt(Math.Max(0.0, edgeSpeed * edgeSpeed + well));
	}

	/// <summary>
	/// For a pass with periapsis <paramref name="periapsis"/> and well-edge speed <paramref name="edgeSpeed"/>: the angle
	/// from the periapsis direction to the velocity when leaving the well. The total turn of a flyby is 2*angle - pi.
	/// </summary>
	public static double ExitAngle(BodyDef body, double edgeSpeed, double periapsis)
	{
		double mu = body.Mu;
		double edge = Math.Min(body.GravityRadius, 1e9);
		double vp = SpeedAtRadius(body, edgeSpeed, periapsis);
		double h = periapsis * vp;
		double energy = 0.5 * vp * vp - mu / periapsis;
		double p = h * h / mu;
		double e = Math.Sqrt(Math.Max(1e-12, 1.0 + 2.0 * energy * h * h / (mu * mu)));
		double theta = Math.Acos(Math.Clamp((p / edge - 1.0) / e, -1.0, 1.0));
		double gamma = Math.Atan2(e * Math.Sin(theta), 1.0 + e * Math.Cos(theta));
		return theta + 0.5 * Math.PI - gamma;
	}

	public static double CaptureCost(BodyDef body, double edgeSpeed, double periapsis)
	{
		return Math.Abs(SpeedAtRadius(body, edgeSpeed, periapsis) - Math.Sqrt(body.Mu / periapsis));
	}

	public static TransferPlan Plan(Ephemeris eph, TransferRequest req)
	{
		var plan = new TransferPlan { TargetBody = req.Target };
		BodyDef[] bodies = eph.Bodies;
		if (req.Target < 0 || req.Target >= eph.Count)
		{
			plan.Message = "invalid_target";
			return plan;
		}

		int n = eph.Count;
		var bp = new Vector2D[n];
		var bv = new Vector2D[n];
		double t0 = req.Time;
		eph.ComputeStates(t0, bp, bv);

		int target = req.Target;
		int local = eph.FindDominant(req.Position, bp);
		if (local < 0)
			local = 0;
		double targetPeriapsis = req.ArrivalPeriapsis > 0.0 ? req.ArrivalPeriapsis : DefaultPeriapsis(bodies[target]);

		if (target == local || eph.IsAncestorOf(target, local))
		{
			// Already inside the target's sphere of influence: just settle into orbit.
			plan.Valid = true;
			plan.Message = "already_in_sphere";
			plan.CentralBody = target;
			plan.ArrivalBody = target;
			plan.Encounters.Add(new PlannedEncounter
			{
				Body = target, Time = t0, Periapsis = targetPeriapsis, Capture = req.Capture, IsFinal = true,
			});
			if (req.Capture)
				plan.Burns.Add(new PlannedBurn { Kind = BurnKind.CapturePeriapsis, Time = t0 + req.MinLeadTime, Body = target });
			return plan;
		}

		int central = eph.CommonAncestor(local, target);
		int arrival = eph.ChildToward(central, target);
		int departure = local == central ? -1 : eph.ChildToward(central, local);
		plan.CentralBody = central;
		plan.ArrivalBody = arrival;
		plan.DepartureBody = departure;

		double muC = bodies[central].Mu;
		bool retrograde = bodies[arrival].Orbit.Retrograde;
		double arrivalPeriapsis = arrival == target ? targetPeriapsis : DefaultPeriapsis(bodies[arrival]);
		double arrivalMu = bodies[arrival].Mu;
		// Stops on the way to a moon always capture, so the next hop departs from a proper orbit.
		bool captureAtArrival = req.Capture || arrival != target;

		double rDep = departure >= 0 ? (bp[departure] - bp[central]).Length : (req.Position - bp[central]).Length;
		double rArr = (bp[arrival] - bp[central]).Length;
		double hohmann = HohmannTime(rDep, rArr, muC);
		double periodDep = departure >= 0 ? eph.OrbitPeriod(departure) : 2.0 * Math.PI * Math.Sqrt(rDep * rDep * rDep / muC);
		double periodArr = eph.OrbitPeriod(arrival);
		double synodic = 1.0 / Math.Abs(1.0 / periodDep - 1.0 / periodArr);
		if (!double.IsFinite(synodic))
			synodic = 2.0 * hohmann;
		double window = req.MaxSearchWindow > 0.0
			? req.MaxSearchWindow
			: Math.Clamp(synodic, hohmann * 0.5, hohmann * 4.0);

		// Coast the ship along its current path to know where it will be at each candidate departure.
		int coastSteps = (int)Math.Ceiling((window + req.MinLeadTime) / req.Dt) + 1;
		var coast = TrajectoryPredictor.Predict(eph, req.Position, req.Velocity, t0, new PredictionSettings
		{
			Dt = req.Dt,
			MaxSteps = coastSteps,
			SampleEvery = Math.Max(1, coastSteps / (req.DepartureSamples * 32)),
			RecordApsides = false,
			ShipRadius = req.ShipRadius,
		});

		DepartureState GetDeparture(int sampleIndex)
		{
			double t = coast.Times[sampleIndex];
			eph.GetState(central, t, out Vector2D cPos, out Vector2D cVel);
			var ds = new DepartureState { SampleIndex = sampleIndex, Time = t };
			Vector2D shipPos = coast.Positions[sampleIndex];
			Vector2D shipVel = coast.Velocities[sampleIndex];
			if (departure < 0)
			{
				ds.R1 = shipPos - cPos;
				ds.VHave = shipVel - cVel;
			}
			else
			{
				eph.GetState(departure, t, out Vector2D sPos, out Vector2D sVel);
				ds.R1 = sPos - cPos;
				ds.VHave = sVel - cVel;
				ds.ShipRel = shipPos - sPos;
				ds.ShipRelVel = shipVel - sVel;
			}
			return ds;
		}

		double DepartureCost(Vector2D v1, in DepartureState ds)
		{
			Vector2D excess = v1 - ds.VHave;
			if (departure < 0)
				return excess.Length;
			double r = ds.ShipRel.Length;
			double periapsisSpeed = SpeedAtRadius(bodies[departure], excess.Length, r);
			return Math.Abs(periapsisSpeed - ds.ShipRelVel.Length);
		}

		// An intercept burns nothing on arrival, but slow arrivals are still preferred: fast crossings are hard to aim
		// precisely and expensive to stop from afterwards (e.g. to park). They count at a quarter of a capture.
		double ArrivalCost(Vector2D vInfinity) =>
			CaptureCost(bodies[arrival], vInfinity.Length, arrivalPeriapsis) * (captureAtArrival ? 1.0 : 0.25);

		bool StateRelativeToCentral(int body, double t, out Vector2D r, out Vector2D v)
		{
			eph.GetState(central, t, out Vector2D cPos, out Vector2D cVel);
			eph.GetState(body, t, out Vector2D p, out Vector2D vel);
			r = p - cPos;
			v = vel - cVel;
			return true;
		}

		var departures = new List<DepartureState>();
		double earliest = t0 + req.MinLeadTime;
		for (int i = 0; i < req.DepartureSamples; i++)
		{
			double td = earliest + window * i / req.DepartureSamples;
			if (td > coast.FinalTime)
				break;
			int si = coast.SampleIndexAt(td);
			if (coast.Times[si] < earliest && si + 1 < coast.Times.Count)
				si++;
			departures.Add(GetDeparture(si));
		}
		if (departures.Count == 0)
		{
			plan.Message = coast.EndReason == "collision" ? "on_collision_course" : "no_departure_window";
			return plan;
		}

		// --- Direct transfer search ---
		var best = new Candidate { Cost = double.PositiveInfinity };
		// Best candidate per departure time, to shortlist several windows for ejection targeting below.
		var perDeparture = new List<Candidate>();
		foreach (DepartureState ds in departures)
		{
			var bestHere = new Candidate { Cost = double.PositiveInfinity };
			for (int j = 0; j < req.TimeOfFlightSamples; j++)
			{
				double tof = hohmann * (0.35 + 1.65 * j / Math.Max(1, req.TimeOfFlightSamples - 1));
				double ta = ds.Time + tof;
				StateRelativeToCentral(arrival, ta, out Vector2D r2, out Vector2D vArr);
				if (!Lambert.Solve(ds.R1, r2, tof, muC, retrograde, out Vector2D v1, out Vector2D v2))
					continue;
				double dep = DepartureCost(v1, ds);
				double arr = ArrivalCost(v2 - vArr);
				double cost = dep + arr;
				if (cost < bestHere.Cost)
				{
					bestHere = new Candidate
					{
						Cost = cost, DepartureCost = dep, ArrivalCost = arr, Departure = ds, V1 = v1, ArrivalTime = ta,
						FlybyTime = double.NaN,
					};
				}
			}
			if (double.IsFinite(bestHere.Cost))
			{
				perDeparture.Add(bestHere);
				if (bestHere.Cost < best.Cost)
					best = bestHere;
			}
		}

		// --- Gravity assist search ---
		var bestAssist = new Candidate { Cost = double.PositiveInfinity };
		int assistBody = -1;
		if (req.AllowGravityAssist)
		{
			int stride = Math.Max(1, departures.Count / Math.Max(1, req.AssistSamples));
			int samples = Math.Max(2, req.AssistSamples);
			foreach (int g in eph.ChildrenOf(central))
			{
				if (g == arrival || g == departure)
					continue;
				BodyDef gBody = bodies[g];
				double rG = eph.OrbitRadius(g);
				// Keep the flyby inside the orbits of the body's moons so the pass cannot hit one.
				double minFlyby = gBody.Radius * 1.15;
				foreach (int moon in eph.ChildrenOf(g))
					minFlyby = Math.Max(minFlyby, eph.OrbitRadius(moon) + bodies[moon].SphereOfInfluence);
				double h1 = HohmannTime(rDep, rG, muC);
				double h2 = HohmannTime(rG, rArr, muC);
				for (int di = 0; di < departures.Count; di += stride)
				{
					DepartureState ds = departures[di];
					for (int j1 = 0; j1 < samples; j1++)
					{
						double tof1 = h1 * (0.3 + 1.7 * j1 / (samples - 1));
						double tg = ds.Time + tof1;
						StateRelativeToCentral(g, tg, out Vector2D rGPos, out Vector2D vG);
						if (!Lambert.Solve(ds.R1, rGPos, tof1, muC, retrograde, out Vector2D v1, out Vector2D vGArrive))
							continue;
						double dep = DepartureCost(v1, ds);
						if (dep >= bestAssist.Cost || dep >= best.Cost)
							continue;
						Vector2D vIn = vGArrive - vG;
						for (int j2 = 0; j2 < samples; j2++)
						{
							double tof2 = h2 * (0.3 + 1.7 * j2 / (samples - 1));
							double ta = tg + tof2;
							StateRelativeToCentral(arrival, ta, out Vector2D r2, out Vector2D vArr);
							if (!Lambert.Solve(rGPos, r2, tof2, muC, retrograde, out Vector2D vGLeave, out Vector2D v2))
								continue;
							Vector2D vOut = vGLeave - vG;
							if (!FlybyCost(gBody, vIn, vOut, minFlyby, out double flybyRp, out double flybyDv))
								continue;
							double arr = ArrivalCost(v2 - vArr);
							double cost = dep + Math.Abs(flybyDv) + arr;
							if (cost < bestAssist.Cost)
							{
								bestAssist = new Candidate
								{
									Cost = cost, DepartureCost = dep, FlybyCost = Math.Abs(flybyDv), ArrivalCost = arr,
									Departure = ds, V1 = v1, FlybyTime = tg, ArrivalTime = ta,
									FlybyPeriapsisSigned = vIn.Cross(vOut) >= 0.0 ? flybyRp : -flybyRp,
									FlybyProgradeDv = flybyDv,
								};
								assistBody = g;
							}
						}
					}
				}
			}
		}

		bool useAssist = assistBody >= 0 && bestAssist.Cost < best.Cost * req.AssistAdvantage;
		Candidate chosen = useAssist ? bestAssist : best;
		if (!double.IsFinite(chosen.Cost))
		{
			plan.Message = "no_transfer_found";
			return plan;
		}

		// --- Build the maneuver list ---
		PlannedBurn departureBurn = null;
		bool ejectionScanned = false;
		if (!useAssist && departure >= 0 && req.Refine)
		{
			// Patched conics misjudge escapes when the planet's star raises big tides, so the cheapest-looking window
			// can need a far bigger burn in reality. Run the real escape targeting on a shortlist of windows and keep
			// the cheapest actual departure.
			double bestActual = double.PositiveInfinity;
			// Windows within one parking orbit collapse to the same escape after the scan: space them a period apart.
			DepartureState first = departures[0];
			double parkingPeriod = 2.0 * Math.PI * first.ShipRel.LengthSquared /
				Math.Max(Math.Abs(first.ShipRel.Cross(first.ShipRelVel)), 1e-9);
			foreach (Candidate c in Shortlist(perDeparture, 4, parkingPeriod))
			{
				PlannedBurn burn = BuildEjectionBurn(eph, coast, departure, central, c, arrival, c.ArrivalTime, retrograde,
					req, t0);
				if (burn == null)
					continue;
				ScanEjection(eph, coast, burn, req.Dt, central, arrival, c.ArrivalTime, retrograde, t0 + req.MinLeadTime,
					req.Engine);
				double actual = burn.DeltaV.Length + c.ArrivalCost;
				Trace?.Invoke($"window t={c.Departure.Time:F0} estimate={c.Cost:F1} actual={actual:F1}");
				if (actual < bestActual)
				{
					bestActual = actual;
					chosen = c;
					departureBurn = burn;
				}
			}
			ejectionScanned = departureBurn != null;
			if (ejectionScanned)
				chosen.Cost = bestActual;
		}
		departureBurn ??= departure < 0
			? new PlannedBurn
			{
				Kind = BurnKind.Impulse, Time = chosen.Departure.Time, DeltaV = chosen.V1 - chosen.Departure.VHave,
			}
			: BuildEjectionBurn(eph, coast, departure, central, chosen, useAssist ? assistBody : arrival,
				useAssist ? chosen.FlybyTime : chosen.ArrivalTime, retrograde, req, t0);
		if (departureBurn == null)
		{
			plan.Message = "no_ejection_window";
			return plan;
		}
		plan.Burns.Add(departureBurn);

		if (useAssist)
		{
			plan.AssistBody = assistBody;
			plan.Encounters.Add(new PlannedEncounter
			{
				Body = assistBody, Time = chosen.FlybyTime, Periapsis = chosen.FlybyPeriapsisSigned, Capture = false,
				IsFinal = false,
			});
			plan.Burns.Add(new PlannedBurn
			{
				Kind = BurnKind.FlybyPeriapsis, Time = chosen.FlybyTime, ProgradeDeltaV = chosen.FlybyProgradeDv,
				Body = assistBody,
			});
		}
		plan.Encounters.Add(new PlannedEncounter
		{
			Body = arrival,
			Time = chosen.ArrivalTime,
			Periapsis = retrograde ? -arrivalPeriapsis : arrivalPeriapsis,
			Capture = captureAtArrival,
			IsFinal = arrival == target,
		});
		if (captureAtArrival)
			plan.Burns.Add(new PlannedBurn { Kind = BurnKind.CapturePeriapsis, Time = chosen.ArrivalTime, Body = arrival });

		plan.EstimatedDeltaV = chosen.Cost;
		plan.Valid = true;
		plan.Message = useAssist ? "gravity_assist" : "direct";

		// --- Targeting against the real n-body field ---
		if (req.Refine)
		{
			PlannedEncounter first = plan.Encounters[0];
			double legTime = first.Time - departureBurn.Time;
			double horizon = first.Time + Math.Max(legTime * 0.5, 60.0);
			// Start from the coasted state instead of re-integrating the parking orbit every time.
			int burnSample = coast.SampleIndexAt(departureBurn.Time + req.Dt * 0.5);
			Vector2D burnPos, burnVel;
			departureBurn.Time = coast.Times[burnSample];
			if (departureBurn.Kind == BurnKind.Ejection && !ejectionScanned)
			{
				ScanEjection(eph, coast, departureBurn, req.Dt, central, first.Body, first.Time, retrograde,
					t0 + req.MinLeadTime, req.Engine);
			}
			// Simulations start from the coasted state just before the (finite) burn begins.
			double burnStart = Math.Max(t0, departureBurn.Time - 0.5 * req.Engine.Make(departureBurn.Time, departureBurn.DeltaV).Duration - req.Dt);
			burnSample = coast.SampleIndexAt(burnStart + req.Dt * 0.5);
			burnStart = coast.Times[burnSample];
			burnPos = coast.Positions[burnSample];
			burnVel = coast.Velocities[burnSample];
			var targeter = new Targeter(eph, burnPos, burnVel, burnStart, req.Dt, first.Body, first.Periapsis,
				first.Time, false, horizon, req.Engine, req.ShipRadius);
			RefineResult refined = targeter.Newton(departureBurn.Time, departureBurn.DeltaV, 6,
				1.25 * departureBurn.DeltaV.Length + 2.0);
			if (refined.HasEncounter)
			{
				departureBurn.DeltaV = refined.DeltaV;
				departureBurn.Time = refined.BurnTime;
				double shift = refined.EncounterTime - first.Time;
				first.Time = refined.EncounterTime;
				if (!useAssist)
				{
					foreach (PlannedBurn burn in plan.Burns)
					{
						if (burn.Kind == BurnKind.CapturePeriapsis)
							burn.Time += shift;
					}
				}
				else
				{
					plan.Burns[1].Time = refined.EncounterTime;
				}
			}
			plan.Refined = refined.Converged;
			plan.RefineMiss = refined.Miss;
		}
		if (departureBurn.Kind == BurnKind.Ejection)
			SetOrbitalReference(eph, coast, departureBurn, req.Dt);
		return plan;
	}

	private static void SetOrbitalReference(Ephemeris eph, PredictionResult coast, PlannedBurn burn, double dt)
	{
		int si = coast.SampleIndexAt(burn.Time + dt * 0.5);
		eph.GetState(burn.Body, coast.Times[si], out Vector2D bodyPos, out Vector2D bodyVel);
		Vector2D rel = coast.Positions[si] - bodyPos;
		Vector2D relVel = coast.Velocities[si] - bodyVel;
		double spin = rel.Cross(relVel) >= 0.0 ? 1.0 : -1.0;
		Vector2D radial = rel.Normalized();
		Vector2D along = radial.Perpendicular * spin;
		burn.ReferenceAngle = rel.Angle;
		burn.LocalDeltaV = new Vector2D(burn.DeltaV.Dot(radial), burn.DeltaV.Dot(along));
	}

	/// <summary>The cheapest <paramref name="count"/> candidates whose departures are at least <paramref name="spacing"/> apart.</summary>
	private static List<Candidate> Shortlist(List<Candidate> candidates, int count, double spacing)
	{
		var sorted = new List<Candidate>(candidates);
		sorted.Sort((a, b) => a.Cost.CompareTo(b.Cost));
		var picked = new List<Candidate>();
		foreach (Candidate c in sorted)
		{
			if (picked.Count >= count)
				break;
			if (picked.TrueForAll(p => Math.Abs(p.Departure.Time - c.Departure.Time) >= spacing))
				picked.Add(c);
		}
		return picked;
	}

	/// <summary>
	/// Can a flyby of <paramref name="body"/> turn <paramref name="vIn"/> into <paramref name="vOut"/>?
	/// Returns the required periapsis and the burn at periapsis needed to change the excess speed.
	/// </summary>
	/// <param name="minPeriapsis">Lowest allowed periapsis (surface margin, and clear of the body's moons).</param>
	public static bool FlybyCost(BodyDef body, Vector2D vIn, Vector2D vOut, double minPeriapsis, out double periapsis,
		out double progradeDv)
	{
		periapsis = 0.0;
		progradeDv = 0.0;
		double vi = vIn.Length, vo = vOut.Length;
		if (vi < 1e-6 || vo < 1e-6)
			return false;
		double turn = Math.Acos(Math.Clamp(vIn.Dot(vOut) / (vi * vo), -1.0, 1.0));
		double maxPeriapsis = Math.Min(body.SphereOfInfluence, body.GravityRadius) * 0.8;
		if (minPeriapsis >= maxPeriapsis)
			return false;
		double v = 0.5 * (vi + vo);
		double Turn(double rp) => 2.0 * ExitAngle(body, v, rp) - Math.PI;
		// The turn shrinks as the periapsis grows: the deepest allowed pass gives the most bending.
		if (Turn(minPeriapsis) < turn)
			return false;
		if (Turn(maxPeriapsis) >= turn)
			return false; // Barely any bending needed: not a gravity assist, the direct search covers it.
		{
			double lo = minPeriapsis, hi = maxPeriapsis;
			for (int i = 0; i < 40; i++)
			{
				double mid = 0.5 * (lo + hi);
				if (Turn(mid) > turn)
					lo = mid;
				else
					hi = mid;
			}
			periapsis = 0.5 * (lo + hi);
		}
		progradeDv = SpeedAtRadius(body, vo, periapsis) - SpeedAtRadius(body, vi, periapsis);
		return true;
	}

	/// <summary>
	/// Places the escape burn on the parking orbit so the outgoing hyperbola's asymptote points along the
	/// required hyperbolic excess velocity, and burns prograde at that point (Oberth effect).
	/// The Lambert leg is re-solved from the planet's position at the actual burn time, since the burn can only
	/// happen when the ship passes the right point of its parking orbit.
	/// </summary>
	private static PlannedBurn BuildEjectionBurn(Ephemeris eph, PredictionResult coast, int departure, int central,
		Candidate chosen, int legBody, double legEndTime, bool retrograde, TransferRequest req, double t0)
	{
		BodyDef body = eph.Bodies[departure];
		double muC = eph.Bodies[central].Mu;
		DepartureState ds = chosen.Departure;
		double h = ds.ShipRel.Cross(ds.ShipRelVel);
		double hSign = h >= 0.0 ? 1.0 : -1.0;
		double r = ds.ShipRel.Length;
		double parkingPeriod = 2.0 * Math.PI * r * r / Math.Max(Math.Abs(h), 1e-9);
		double earliest = t0 + req.MinLeadTime;
		Vector2D vInf = chosen.V1 - ds.VHave;
		int burnSample = -1;
		double burnTime = ds.Time;

		for (int iteration = 0; iteration < 4; iteration++)
		{
			if (iteration > 0)
			{
				// Re-solve the leg from where the planet actually is when the ship burns.
				eph.GetState(central, burnTime, out Vector2D c1, out Vector2D cv1);
				eph.GetState(departure, burnTime, out Vector2D s1, out Vector2D sv1);
				eph.GetState(central, legEndTime, out Vector2D c2, out _);
				eph.GetState(legBody, legEndTime, out Vector2D e2, out _);
				if (!Lambert.Solve(s1 - c1, e2 - c2, legEndTime - burnTime, muC, retrograde, out Vector2D v1, out _))
					break;
				vInf = v1 - (sv1 - cv1);
			}
			double periapsisAngle = vInf.Angle - hSign * ExitAngle(body, vInf.Length, r);
			int found = FindAngleCrossing(eph, coast, departure, periapsisAngle, hSign,
				Math.Max(earliest, ds.Time - 0.5 * parkingPeriod));
			if (found < 0)
				break;
			bool settled = found == burnSample;
			burnSample = found;
			burnTime = coast.Times[found];
			if (settled)
				break;
		}
		if (burnSample < 0)
			return null;

		eph.GetState(departure, burnTime, out Vector2D sPos, out Vector2D sVel);
		Vector2D rel = coast.Positions[burnSample] - sPos;
		Vector2D relVel = coast.Velocities[burnSample] - sVel;
		double periapsisSpeed = SpeedAtRadius(body, vInf.Length, rel.Length);
		return new PlannedBurn
		{
			Kind = BurnKind.Ejection,
			Time = burnTime,
			DeltaV = relVel.Normalized() * (periapsisSpeed - relVel.Length),
			Body = departure,
		};
	}

	/// <summary>First coast sample after <paramref name="searchFrom"/> where the ship passes <paramref name="angle"/> around <paramref name="body"/>.</summary>
	private static int FindAngleCrossing(Ephemeris eph, PredictionResult coast, int body, double angle, double hSign,
		double searchFrom)
	{
		double previous = double.NaN;
		for (int i = coast.SampleIndexAt(searchFrom); i < coast.Times.Count; i++)
		{
			if (coast.Times[i] < searchFrom || coast.Dominant[i] != body)
			{
				previous = double.NaN;
				continue;
			}
			Vector2D rel = coast.Positions[i] - eph.GetPosition(body, coast.Times[i]);
			double diff = Math.IEEERemainder(rel.Angle - angle, 2.0 * Math.PI) * hSign;
			if (!double.IsNaN(previous) && previous < 0.0 && diff >= 0.0 && previous > -0.5 * Math.PI)
				return -previous < diff ? i - 1 : i;
			previous = diff;
		}
		return -1;
	}

	/// <summary>
	/// Tries the ejection from several points around the parking orbit (tides rotate the escape asymptote, so the
	/// patched-conic burn point is only approximate) and keeps the cheapest burn whose escape matches the transfer.
	/// </summary>
	private static void ScanEjection(Ephemeris eph, PredictionResult coast, PlannedBurn burn, double dt, int central,
		int legBody, double legEndTime, bool retrograde, double earliest, EngineModel engine)
	{
		int body = burn.Body;
		int center = coast.SampleIndexAt(burn.Time + dt * 0.5);
		eph.GetState(body, coast.Times[center], out Vector2D bodyPos, out Vector2D bodyVel);
		Vector2D rel0 = coast.Positions[center] - bodyPos;
		Vector2D relVel0 = coast.Velocities[center] - bodyVel;
		double period = 2.0 * Math.PI * rel0.LengthSquared / Math.Max(Math.Abs(rel0.Cross(relVel0)), 1e-9);

		double bestCost = double.PositiveInfinity;
		const int samples = 12;
		for (int i = 0; i < samples; i++)
		{
			double t = burn.Time + period * ((double)i / samples - 0.5);
			if (t < earliest || t > coast.FinalTime)
				continue;
			int si = coast.SampleIndexAt(t);
			double ts = coast.Times[si];
			eph.GetState(body, ts, out _, out Vector2D v);
			Vector2D relVel = coast.Velocities[si] - v;
			// Same prograde magnitude as the patched-conic estimate, at this point of the orbit.
			Vector2D guess = relVel.Normalized() * burn.DeltaV.Length;
			Vector2D dv = TargetEscape(eph, coast, ts, dt, body, central, legBody, legEndTime, retrograde, guess, engine,
				out double residual);
			if (residual > 0.1)
				continue;
			if (dv.Length < bestCost)
			{
				bestCost = dv.Length;
				burn.Time = ts;
				burn.DeltaV = dv;
			}
		}
		Trace?.Invoke($"ejection scan: t={burn.Time:F1} |dv|={burn.DeltaV.Length:F2}");
	}

	/// <summary>
	/// Escape targeting: adjusts the ejection burn so that, when the ship leaves the departure body's sphere of
	/// influence, its velocity equals the Lambert solution from that exit point to the leg's end. Only the short escape
	/// is integrated, so this is cheap and well-conditioned; it absorbs the tides patched conics ignore.
	/// </summary>
	private static Vector2D TargetEscape(Ephemeris eph, PredictionResult coast, double burnTime, double dt,
		int departure, int central, int legBody, double legEndTime, bool retrograde, Vector2D guess, EngineModel engine,
		out double residualOut)
	{
		residualOut = double.PositiveInfinity;
		// Start a little before the burn so a finite burn centred on burnTime is fully simulated.
		double lead = 0.5 * engine.Make(burnTime, guess * 2.0).Duration + dt;
		int startSample = coast.SampleIndexAt(burnTime - lead);
		double startTime = coast.Times[startSample];
		Vector2D startPos = coast.Positions[startSample];
		Vector2D startVel = coast.Velocities[startSample];
		double muC = eph.Bodies[central].Mu;
		int maxSteps = (int)Math.Ceiling(0.5 * (legEndTime - burnTime) / dt);

		bool Residual(Vector2D dv, out Vector2D residual)
		{
			residual = Vector2D.Zero;
			PredictionResult r = TrajectoryPredictor.Predict(eph, startPos, startVel, startTime, new PredictionSettings
			{
				Dt = dt,
				MaxSteps = maxSteps + (int)Math.Ceiling((burnTime - startTime) / dt),
				RecordSamples = false,
				RecordApsides = false,
				// Past the edge of the gravity well the planet no longer pulls, so the exit state is final.
				StopDistanceFrom = departure,
				StopDistance = Math.Min(eph.Bodies[departure].GravityRadius, 3.0 * eph.Bodies[departure].SphereOfInfluence) + 1.0,
				Burns = new List<ImpulseBurn> { engine.Make(burnTime, dv) },
			});
			if (r.EndReason != "distance")
				return false;
			eph.GetState(central, r.FinalTime, out Vector2D cPos, out Vector2D cVel);
			eph.GetState(central, legEndTime, out Vector2D cEnd, out _);
			Vector2D end = eph.GetPosition(legBody, legEndTime) - cEnd;
			if (!Lambert.Solve(r.FinalPosition - cPos, end, legEndTime - r.FinalTime, muC, retrograde, out Vector2D v1, out _))
				return false;
			residual = r.FinalVelocity - (v1 + cVel);
			return true;
		}

		Vector2D dvCur = guess;
		// Make sure the starting guess escapes at all.
		Vector2D res;
		int grow = 0;
		while (!Residual(dvCur, out res) && grow++ < 8)
			dvCur *= 1.15;
		if (grow > 8)
			return guess;
		residualOut = res.Length;

		for (int iteration = 0; iteration < 12 && res.Length > 0.02; iteration++)
		{
			double h = Math.Max(1e-3, 1e-4 * dvCur.Length);
			if (!Residual(dvCur + new Vector2D(h, 0.0), out Vector2D rx) || !Residual(dvCur + new Vector2D(0.0, h), out Vector2D ry))
				break;
			double a = (rx.X - res.X) / h, b = (ry.X - res.X) / h, c = (rx.Y - res.Y) / h, d = (ry.Y - res.Y) / h;
			double det = a * d - b * c;
			if (Math.Abs(det) < 1e-12)
				break;
			var step = new Vector2D((d * -res.X - b * -res.Y) / det, (-c * -res.X + a * -res.Y) / det);
			double maxStep = Math.Max(1.0, 0.5 * dvCur.Length);
			if (step.Length > maxStep)
				step = step.Normalized() * maxStep;
			bool accepted = false;
			for (double s = 1.0; s >= 1.0 / 64.0; s *= 0.5)
			{
				Vector2D candidate = dvCur + step * s;
				if (Residual(candidate, out Vector2D rc) && rc.Length < res.Length)
				{
					dvCur = candidate;
					res = rc;
					residualOut = res.Length;
					accepted = true;
					break;
				}
			}
			Trace?.Invoke($"escape {iteration}: dv={dvCur} residual={res.Length:F3}");
			if (!accepted)
				break;
		}
		return dvCur;
	}

	/// <summary>
	/// Newton/shooting targeting: adjusts the delta-v of one burn so the full n-body prediction reaches
	/// <paramref name="body"/> with the signed periapsis <paramref name="periapsisTarget"/> (and, if
	/// <paramref name="constrainTime"/>, at <paramref name="expectedTime"/>). Used for departure refinement and
	/// mid-course corrections.
	/// </summary>
	public static RefineResult Refine(Ephemeris eph, Vector2D position, Vector2D velocity, double t0, double dt,
		double burnTime, Vector2D deltaVGuess, int body, double periapsisTarget, double expectedTime, bool constrainTime,
		double horizonEnd, int maxIterations = 16, double maxDeltaV = double.PositiveInfinity, EngineModel engine = default,
		double shipRadius = 0.0)
	{
		var targeter = new Targeter(eph, position, velocity, t0, dt, body, periapsisTarget, expectedTime, constrainTime,
			horizonEnd, engine, shipRadius);
		return targeter.Newton(burnTime, deltaVGuess, maxIterations, maxDeltaV);
	}

	private struct Evaluation
	{
		public bool Ok;
		public double Periapsis;
		public double Time;
		public double Aim;
	}

	/// <summary>
	/// Shooting problem: one burn, one encounter. Rather than periapsis directly (which flattens out near the planet
	/// and jumps on impact) the residual is the specific angular momentum about the body versus what the target
	/// periapsis needs at the measured energy — the 2D equivalent of B-plane targeting, nearly linear in the aim point.
	/// </summary>
	private sealed class Targeter
	{
		public readonly Ephemeris Ephemeris;
		private readonly Vector2D _position;
		private readonly Vector2D _velocity;
		private readonly double _t0;
		private readonly double _dt;
		private readonly int _body;
		private readonly BodyDef _target;
		private readonly double _periapsisTarget;
		private readonly double _expectedTime;
		private readonly bool _timed;
		private readonly int _steps;
		private readonly EphemerisTable _table;
		private readonly double _tolR, _scaleR, _tolT, _scaleT;
		private readonly EngineModel _engine;
		private readonly double _shipRadius;

		public Targeter(Ephemeris eph, Vector2D position, Vector2D velocity, double t0, double dt, int body,
			double periapsisTarget, double expectedTime, bool constrainTime, double horizonEnd, EngineModel engine,
			double shipRadius)
		{
			Ephemeris = eph;
			_engine = engine;
			_shipRadius = shipRadius;
			_position = position;
			_velocity = velocity;
			_t0 = t0;
			_dt = dt;
			_body = body;
			_target = eph.Bodies[body];
			_periapsisTarget = periapsisTarget;
			_expectedTime = expectedTime;
			_timed = constrainTime && double.IsFinite(expectedTime);
			_steps = (int)Math.Ceiling((horizonEnd - t0) / dt) + 1;
			_table = _steps <= MaxTableSteps ? new EphemerisTable(eph, t0, dt, _steps) : null;
			double rp = Math.Abs(periapsisTarget);
			_tolR = Math.Max(0.1 * rp, 0.25 * _target.Radius);
			_scaleR = Math.Max(rp, _target.Radius);
			_tolT = _timed ? Math.Max(1.0, 0.01 * (expectedTime - t0)) : double.PositiveInfinity;
			_scaleT = _timed ? _tolT : 1.0;
		}

		public Evaluation Evaluate(double burnTime, Vector2D dv)
		{
			var settings = new PredictionSettings
			{
				Dt = _dt,
				MaxSteps = _steps,
				RecordSamples = false,
				RecordApsides = false,
				WatchBody = _body,
				WatchFrom = burnTime,
				ShipRadius = _shipRadius,
				Burns = new List<ImpulseBurn> { _engine.Make(burnTime, dv) },
			};
			PredictionResult r = TrajectoryPredictor.Predict(Ephemeris, _position, _velocity, _t0, settings, _table);
			var e = new Evaluation { Ok = r.HasClosestApproach };
			if (!e.Ok)
				return e;
			e.Periapsis = r.ClosestApproachSigned;
			e.Time = r.ClosestApproachTime;
			if (!r.ClosestApproachIsMinimum || r.ClosestApproachDistance > _target.GravityRadius)
			{
				// No real encounter (still closing, receding from the start, or passing outside the gravity well where
				// angular momentum says nothing about the periapsis): plain signed miss distance.
				e.Aim = e.Periapsis - _periapsisTarget;
				return e;
			}
			Vector2D rel = r.ClosestApproachRelPosition;
			Vector2D relVel = r.ClosestApproachRelVelocity;
			double rpTarget = Math.Abs(_periapsisTarget);
			double side = _periapsisTarget >= 0.0 ? 1.0 : -1.0;
			double energy = 0.5 * relVel.LengthSquared - _target.Mu / rel.Length;
			double periapsisSpeed = Math.Sqrt(Math.Max(0.0, 2.0 * (energy + _target.Mu / rpTarget)));
			double hTarget = side * rpTarget * periapsisSpeed;
			// Angular momentum error expressed as a distance at periapsis.
			e.Aim = (rel.Cross(relVel) - hTarget) / Math.Max(periapsisSpeed, 1e-6);
			return e;
		}

		public double Error(Evaluation e)
		{
			if (!e.Ok)
				return double.PositiveInfinity;
			double er = e.Aim / _scaleR;
			double et = _timed ? (e.Time - _expectedTime) / _scaleT : 0.0;
			return er * er + et * et;
		}

		private bool Converged(Evaluation e) =>
			e.Ok && Math.Abs(e.Periapsis - _periapsisTarget) <= _tolR
				&& (!_timed || Math.Abs(e.Time - _expectedTime) <= _tolT);

		/// <param name="maxDeltaV">Candidates above this burn size are rejected, so the solver cannot wander off to an
		/// expensive solution in another basin.</param>
		public RefineResult Newton(double burnTime, Vector2D guess, int maxIterations, double maxDeltaV = double.PositiveInfinity)
		{
			Vector2D dvCur = guess;
			Evaluation cur = Evaluate(burnTime, dvCur);
			double initialMiss = cur.Ok ? Math.Abs(cur.Periapsis - _periapsisTarget) : double.PositiveInfinity;
			int iteration = 0;
			for (; iteration < maxIterations && cur.Ok && !Converged(cur); iteration++)
			{
				Trace?.Invoke($"refine {iteration}: dv={dvCur} rp={cur.Periapsis:F1}/{_periapsisTarget:F1} aim={cur.Aim:F1} t={cur.Time:F1}/{_expectedTime:F1}");
				double h = Math.Max(1e-3, dvCur.Length * 1e-4);
				Evaluation ex = Evaluate(burnTime, dvCur + new Vector2D(h, 0.0));
				Evaluation ey = Evaluate(burnTime, dvCur + new Vector2D(0.0, h));
				if (!ex.Ok || !ey.Ok)
					break;

				var gradAim = new Vector2D((ex.Aim - cur.Aim) / h, (ey.Aim - cur.Aim) / h);
				Vector2D step = Vector2D.Zero;
				bool solved = false;
				if (_timed)
				{
					var gradT = new Vector2D((ex.Time - cur.Time) / h, (ey.Time - cur.Time) / h);
					// 2x2 Newton system in normalised units.
					double a = gradAim.X / _scaleR, b = gradAim.Y / _scaleR, c = gradT.X / _scaleT, d = gradT.Y / _scaleT;
					double det = a * d - b * c;
					double nr = -cur.Aim / _scaleR, nt = (_expectedTime - cur.Time) / _scaleT;
					if (Math.Abs(det) > 1e-12)
					{
						step = new Vector2D((d * nr - b * nt) / det, (-c * nr + a * nt) / det);
						solved = true;
					}
				}
				if (!solved)
				{
					double g2 = gradAim.LengthSquared;
					if (g2 <= 0.0)
						break;
					step = gradAim * (-cur.Aim / g2); // Minimum-norm correction: one equation, two unknowns.
				}

				double maxStep = Math.Max(1.0, 0.5 * Math.Max(dvCur.Length, 2.0));
				if (step.Length > maxStep)
					step = step.Normalized() * maxStep;

				double currentError = Error(cur);
				bool accepted = false;
				for (double s = 1.0; s >= 1.0 / 64.0; s *= 0.5)
				{
					Vector2D candidate = dvCur + step * s;
					if (candidate.Length > maxDeltaV)
						continue;
					Evaluation e = Evaluate(burnTime, candidate);
					if (Error(e) < currentError)
					{
						dvCur = candidate;
						cur = e;
						accepted = true;
						break;
					}
				}
				if (!accepted)
				{
					Trace?.Invoke($"refine {iteration}: line search failed, step={step}");
					break;
				}
			}

			return new RefineResult
			{
				Iterations = iteration,
				BurnTime = burnTime,
				DeltaV = dvCur,
				HasEncounter = cur.Ok,
				Periapsis = cur.Periapsis,
				EncounterTime = cur.Time,
				Miss = cur.Ok ? Math.Abs(cur.Periapsis - _periapsisTarget) : double.PositiveInfinity,
				InitialMiss = initialMiss,
				Converged = Converged(cur),
			};
		}
	}
}
