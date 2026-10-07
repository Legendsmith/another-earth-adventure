using System;
using System.Collections.Generic;

namespace AnotherEarth.Orbital;

/// <summary>
/// A planned change in velocity. Impulsive by default (applied at the first physics tick at or after <see cref="Time"/>);
/// with <see cref="Thrust"/> set it is a finite burn centred on <see cref="Time"/>, thrusting along a fixed direction
/// with decreasing mass, exactly like Spaceship.gd executes it. Long burns in tight orbits lose a lot to gravity and
/// rotation, so targeting must model them.
/// </summary>
public struct ImpulseBurn
{
	public double Time;
	public Vector2D DeltaV;
	/// <summary>Engine force; 0 = impulsive.</summary>
	public double Thrust;
	/// <summary>Ship mass when the burn starts.</summary>
	public double Mass;
	public double ExhaustVelocity;
	/// <summary>
	/// When set, <see cref="DeltaV"/> is (prograde, radial-out) relative to the dominant body when the burn starts,
	/// instead of an inertial vector. This is how player maneuver nodes are defined and executed.
	/// </summary>
	public bool OrbitalFrame;

	public ImpulseBurn(double time, Vector2D deltaV)
	{
		Time = time;
		DeltaV = deltaV;
		Thrust = 0.0;
		Mass = 0.0;
		ExhaustVelocity = 0.0;
		OrbitalFrame = false;
	}

	public bool IsFinite => Thrust > 0.0 && Mass > 0.0 && ExhaustVelocity > 0.0;

	/// <summary>Burn duration from the rocket equation.</summary>
	public double Duration => IsFinite
		? Mass * (1.0 - Math.Exp(-DeltaV.Length / ExhaustVelocity)) / (Thrust / ExhaustVelocity)
		: 0.0;

	/// <summary>Prograde/radial-out unit vectors of a ship state relative to a body.</summary>
	public static void OrbitalAxes(Vector2D relPosition, Vector2D relVelocity, out Vector2D prograde, out Vector2D radialOut)
	{
		prograde = relVelocity.Normalized();
		if (prograde.LengthSquared == 0.0)
			prograde = relPosition.Normalized().Perpendicular;
		radialOut = prograde.Perpendicular;
		if (radialOut.Dot(relPosition) < 0.0)
			radialOut = -radialOut;
	}

	public double StartTime => Time - 0.5 * Duration;
}

/// <summary>Ship engine parameters used to turn planned delta-v into finite burns.</summary>
public readonly struct EngineModel
{
	public readonly double Thrust;
	public readonly double Mass;
	public readonly double ExhaustVelocity;

	public EngineModel(double thrust, double mass, double exhaustVelocity)
	{
		Thrust = thrust;
		Mass = mass;
		ExhaustVelocity = exhaustVelocity;
	}

	public ImpulseBurn Make(double time, Vector2D deltaV) => new(time, deltaV)
	{
		Thrust = Thrust,
		Mass = Mass,
		ExhaustVelocity = ExhaustVelocity,
	};
}

public sealed class PredictionSettings
{
	/// <summary>Must equal the physics tick length for the prediction to match the engine.</summary>
	public double Dt = 1.0 / 60.0;
	public int MaxSteps = 36000;
	/// <summary>
	/// Radius of the ship's hull. Godot applies an area's gravity (and reports a collision) as soon as the hull
	/// overlaps it, not when the ship's centre crosses, so gravity wells reach this much further and bodies are this
	/// much larger. Leaving it at 0 desynchronises the prediction for about a second at every sphere boundary.
	/// </summary>
	public double ShipRadius;
	/// <summary>Record one path sample every N ticks. Sphere changes are always sampled.</summary>
	public int SampleEvery = 10;
	/// <summary>Stop after the path has wrapped this many times around its current dominant body (0 = never).</summary>
	public double StopAfterOrbits;
	public bool StopOnCollision = true;
	/// <summary>Stop once the ship is farther than <see cref="StopDistance"/> from this body, after all burns (-1 = never).</summary>
	public int StopDistanceFrom = -1;
	public double StopDistance = double.PositiveInfinity;
	public bool RecordApsides = true;
	public bool RecordSamples = true;
	/// <summary>
	/// Body to track the closest approach to, or -1. The closest approach is the first periapsis pass inside the body's
	/// sphere if there is one (otherwise the overall minimum distance). Only tracked while the ship's dominant body is the watched body,
	/// one of its ancestors or one of its moons, so passes while orbiting some other body (e.g. the departure planet) are ignored.
	/// </summary>
	public int WatchBody = -1;
	public double WatchFrom = double.NegativeInfinity;
	public double WatchUntil = double.PositiveInfinity;
	public List<ImpulseBurn> Burns = new();
}

public enum PredictionEventType
{
	SphereEnter,
	SphereExit,
	Periapsis,
	Apoapsis,
	Burn,
	Collision,
	ClosestApproach,
}

public struct PredictionEvent
{
	public PredictionEventType Type;
	public double Time;
	public int Body;
	public Vector2D Position;
	public Vector2D Velocity;
	public double Distance;
}

public sealed class PredictionResult
{
	public double StartTime;
	public int InitialDominant = -1;
	public readonly List<double> Times = new();
	public readonly List<Vector2D> Positions = new();
	public readonly List<Vector2D> Velocities = new();
	public readonly List<int> Dominant = new();
	public readonly List<PredictionEvent> Events = new();

	public Vector2D FinalPosition;
	public Vector2D FinalVelocity;
	public double FinalTime;
	public int Steps;
	public string EndReason = "horizon";

	public bool HasClosestApproach;
	public double ClosestApproachTime;
	public double ClosestApproachDistance = double.PositiveInfinity;
	/// <summary>Ship position relative to the watched body at closest approach.</summary>
	public Vector2D ClosestApproachRelPosition;
	public Vector2D ClosestApproachRelVelocity;
	/// <summary>False when the closest approach is at the first or last tracked tick (the ship never turned back).</summary>
	public bool ClosestApproachIsMinimum;
	internal double WatchFirstTime = double.NaN;
	internal bool ClosestApproachInside;
	/// <summary>Set after the first periapsis pass inside the watched body's sphere; later passes are ignored.</summary>
	public bool ClosestApproachLocked;
	internal double WatchLastTime = double.NaN;

	/// <summary>Closest approach distance signed by the direction of the pass (positive = positive angular momentum about the body).</summary>
	public double ClosestApproachSigned =>
		ClosestApproachRelPosition.Cross(ClosestApproachRelVelocity) >= 0.0 ? ClosestApproachDistance : -ClosestApproachDistance;

	/// <summary>Index of the last sample at or before <paramref name="time"/>.</summary>
	public int SampleIndexAt(double time)
	{
		int index = Times.BinarySearch(time);
		if (index < 0)
			index = ~index - 1;
		return Math.Clamp(index, 0, Times.Count - 1);
	}
}

/// <summary>
/// Integrates a ship through the gravity field of the bodies on rails using exactly the same scheme as
/// Godot's 2D physics server, so a prediction made from the ship's current state follows the real body:
/// <list type="number">
/// <item>Scripts run: the <see cref="OrbitalSystem"/> advances time and places every body for time t.</item>
/// <item>The physics step sums point gravity of every Area2D the ship overlaps, then v += a·dt; x += v·dt (semi-implicit Euler).</item>
/// </list>
/// A state read during a physics frame at simulation time t is therefore integrated with bodies at t.
/// </summary>
public static class TrajectoryPredictor
{
	public static PredictionResult Predict(Ephemeris ephemeris, Vector2D position, Vector2D velocity, double startTime,
		PredictionSettings settings, EphemerisTable table = null)
	{
		var result = new PredictionResult { StartTime = startTime };
		int n = ephemeris.Count;
		BodyDef[] bodies = ephemeris.Bodies;
		var bodyPos = new Vector2D[n];
		var bodyVel = new Vector2D[n];
		double dt = settings.Dt;
		double shipRadius = Math.Max(0.0, settings.ShipRadius);
		// Tables are shared between predictions starting at different ticks of the same grid.
		int tableOffset = table != null ? (int)Math.Round((startTime - table.StartTime) / dt) : 0;
		bool useTable = table != null && table.Dt == dt && tableOffset >= 0
			&& Math.Abs(table.StartTime + tableOffset * dt - startTime) < dt * 1e-3;

		List<ImpulseBurn> burns = settings.Burns ?? new List<ImpulseBurn>();
		burns.Sort((a, b) => a.StartTime.CompareTo(b.StartTime));
		int burnIndex = 0;
		// State of the finite burn in progress.
		double activeRemaining = 0.0, activeThrust = 0.0, activeMass = 0.0, activeExhaust = 0.0;
		Vector2D activeDirection = Vector2D.Zero;

		Vector2D pos = position;
		Vector2D vel = velocity;

		LoadStates(ephemeris, table, useTable, tableOffset, startTime, bodyPos, bodyVel);
		int dominant = ephemeris.FindDominant(pos, bodyPos);
		result.InitialDominant = dominant;
		AddSample(result, settings, startTime, pos, vel, dominant);

		double prevRadial = double.NaN;
		double prevAngle = dominant >= 0 ? (pos - bodyPos[dominant]).Angle : 0.0;
		double sweep = 0.0;
		double time = startTime;

		for (int k = 0; k < settings.MaxSteps; k++)
		{
			time = startTime + k * dt;
			LoadStates(ephemeris, table, useTable, tableOffset + k, time, bodyPos, bodyVel);

			while (activeRemaining <= 0.0 && burnIndex < burns.Count && burns[burnIndex].StartTime <= time + dt * 1e-3)
			{
				ImpulseBurn burn = burns[burnIndex++];
				if (burn.OrbitalFrame)
				{
					Vector2D relPos = dominant >= 0 ? pos - bodyPos[dominant] : pos;
					Vector2D relVel = dominant >= 0 ? vel - bodyVel[dominant] : vel;
					ImpulseBurn.OrbitalAxes(relPos, relVel, out Vector2D prograde, out Vector2D radialOut);
					burn.DeltaV = prograde * burn.DeltaV.X + radialOut * burn.DeltaV.Y;
				}
				if (burn.IsFinite)
				{
					activeRemaining = burn.DeltaV.Length;
					activeDirection = burn.DeltaV.Normalized();
					activeThrust = burn.Thrust;
					activeMass = burn.Mass;
					activeExhaust = burn.ExhaustVelocity;
				}
				else
				{
					vel += burn.DeltaV;
				}
				result.Events.Add(new PredictionEvent
				{
					Type = PredictionEventType.Burn, Time = time, Body = dominant, Position = pos, Velocity = vel,
				});
				prevRadial = double.NaN;
				sweep = 0.0;
			}

			// Engine thrust for this tick (never overshooting the burn, like the ship's last partial tick).
			double tx = 0.0, ty = 0.0;
			if (activeRemaining > 0.0)
			{
				double full = activeThrust / activeMass * dt;
				double dvStep = Math.Min(full, activeRemaining);
				tx = activeDirection.X * dvStep / dt;
				ty = activeDirection.Y * dvStep / dt;
				activeRemaining -= dvStep;
				activeMass -= activeThrust / activeExhaust * dt * (dvStep / full);
				if (activeRemaining < 1e-9)
					activeRemaining = 0.0;
			}
			bool burnsDone = activeRemaining <= 0.0 && burnIndex >= burns.Count;

			// Point gravity of every overlapping area, matching Area2D gravity_point with unit distance = radius.
			double ax = 0.0, ay = 0.0;
			for (int i = 0; i < n; i++)
			{
				double dx = bodyPos[i].X - pos.X;
				double dy = bodyPos[i].Y - pos.Y;
				double r2 = dx * dx + dy * dy;
				double influence = bodies[i].GravityRadius + shipRadius;
				if (r2 > influence * influence || r2 <= 0.0)
					continue;
				double s = bodies[i].Mu / (r2 * Math.Sqrt(r2));
				ax += dx * s;
				ay += dy * s;
			}
			vel = new Vector2D(vel.X + (ax + tx) * dt, vel.Y + (ay + ty) * dt);
			pos = new Vector2D(pos.X + vel.X * dt, pos.Y + vel.Y * dt);
			double newTime = time + dt;

			if (settings.StopOnCollision)
			{
				int hit = FindCollision(bodies, bodyPos, pos, shipRadius);
				if (hit >= 0)
				{
					result.Events.Add(new PredictionEvent
					{
						Type = PredictionEventType.Collision, Time = newTime, Body = hit, Position = pos, Velocity = vel,
						Distance = (pos - bodyPos[hit]).Length,
					});
					TrackClosestApproach(result, settings, newTime, pos, vel, bodyPos, bodyVel, ephemeris, dominant);
					result.EndReason = "collision";
					time = newTime;
					result.Steps = k + 1;
					break;
				}
			}

			int newDominant = ephemeris.FindDominant(pos, bodyPos);
			bool sphereChanged = newDominant != dominant;
			if (sphereChanged)
			{
				RecordSphereChange(ephemeris, result, dominant, newDominant, newTime, pos, vel);
				dominant = newDominant;
				prevRadial = double.NaN;
				sweep = 0.0;
				if (dominant >= 0)
					prevAngle = (pos - bodyPos[dominant]).Angle;
			}

			if (settings.StopDistanceFrom >= 0 && burnsDone
				&& (pos - bodyPos[settings.StopDistanceFrom]).LengthSquared > settings.StopDistance * settings.StopDistance)
			{
				result.EndReason = "distance";
				time = newTime;
				result.Steps = k + 1;
				AddSample(result, settings, newTime, pos, vel, dominant);
				break;
			}

			if (dominant >= 0)
			{
				Vector2D rel = pos - bodyPos[dominant];
				Vector2D relVel = vel - bodyVel[dominant];
				if (settings.RecordApsides)
				{
					double radial = rel.Dot(relVel);
					if (!double.IsNaN(prevRadial))
					{
						PredictionEventType? apsis = null;
						if (prevRadial < 0.0 && radial >= 0.0)
							apsis = PredictionEventType.Periapsis;
						else if (prevRadial > 0.0 && radial <= 0.0)
							apsis = PredictionEventType.Apoapsis;
						if (apsis.HasValue)
						{
							result.Events.Add(new PredictionEvent
							{
								Type = apsis.Value, Time = newTime, Body = dominant, Position = pos, Velocity = vel,
								Distance = rel.Length,
							});
						}
					}
					prevRadial = radial;
				}

				if (settings.StopAfterOrbits > 0.0 && burnsDone)
				{
					double angle = rel.Angle;
					sweep += Math.IEEERemainder(angle - prevAngle, 2.0 * Math.PI);
					prevAngle = angle;
					if (Math.Abs(sweep) >= settings.StopAfterOrbits * 2.0 * Math.PI)
					{
						result.EndReason = "orbit_closed";
						time = newTime;
						result.Steps = k + 1;
						AddSample(result, settings, newTime, pos, vel, dominant);
						TrackClosestApproach(result, settings, newTime, pos, vel, bodyPos, bodyVel, ephemeris, dominant);
						break;
					}
				}
			}

			TrackClosestApproach(result, settings, newTime, pos, vel, bodyPos, bodyVel, ephemeris, dominant);

			if (sphereChanged || (k + 1) % settings.SampleEvery == 0)
				AddSample(result, settings, newTime, pos, vel, dominant);

			time = newTime;
			result.Steps = k + 1;
		}

		if (result.Times.Count == 0 || result.Times[^1] < time)
			AddSample(result, settings, time, pos, vel, dominant);
		result.FinalPosition = pos;
		result.FinalVelocity = vel;
		result.FinalTime = time;

		if (result.HasClosestApproach)
		{
			result.ClosestApproachIsMinimum = result.ClosestApproachTime > result.WatchFirstTime
				&& (result.ClosestApproachTime < result.WatchLastTime || result.EndReason == "collision");
			result.Events.Add(new PredictionEvent
			{
				Type = PredictionEventType.ClosestApproach,
				Time = result.ClosestApproachTime,
				Body = settings.WatchBody,
				Position = ephemeris.GetPosition(settings.WatchBody, result.ClosestApproachTime) + result.ClosestApproachRelPosition,
				Distance = result.ClosestApproachDistance,
			});
		}
		result.Events.Sort((a, b) => a.Time.CompareTo(b.Time));
		return result;
	}

	private static void LoadStates(Ephemeris ephemeris, EphemerisTable table, bool useTable, int step, double time,
		Vector2D[] positions, Vector2D[] velocities)
	{
		if (!useTable || !table.TryCopy(step, positions, velocities))
			ephemeris.ComputeStates(time, positions, velocities);
	}

	private static int FindCollision(BodyDef[] bodies, Vector2D[] bodyPos, Vector2D pos, double shipRadius)
	{
		for (int i = 0; i < bodies.Length; i++)
		{
			double r = bodies[i].Radius + shipRadius;
			if ((pos - bodyPos[i]).LengthSquared < r * r)
				return i;
		}
		return -1;
	}

	private static void AddSample(PredictionResult result, PredictionSettings settings, double time, Vector2D pos,
		Vector2D vel, int dominant)
	{
		if (!settings.RecordSamples)
			return;
		result.Times.Add(time);
		result.Positions.Add(pos);
		result.Velocities.Add(vel);
		result.Dominant.Add(dominant);
	}

	private static void TrackClosestApproach(PredictionResult result, PredictionSettings settings, double time,
		Vector2D pos, Vector2D vel, Vector2D[] bodyPos, Vector2D[] bodyVel, Ephemeris ephemeris, int dominant)
	{
		int w = settings.WatchBody;
		if (w < 0 || time < settings.WatchFrom || time > settings.WatchUntil)
			return;
		// Skip while orbiting unrelated bodies (e.g. still around the departure planet); moons of the target count.
		if (dominant != w && !ephemeris.IsAncestorOf(dominant, w) && !ephemeris.IsAncestorOf(w, dominant))
			return;
		if (double.IsNaN(result.WatchFirstTime))
			result.WatchFirstTime = time;
		result.WatchLastTime = time;
		if (result.ClosestApproachLocked)
			return;
		Vector2D rel = pos - bodyPos[w];
		double d = rel.Length;
		if (d >= result.ClosestApproachDistance)
		{
			// Receding after a periapsis inside the body's sphere: that pass is the encounter. Later (possibly closer)
			// passes belong to a different orbit that the encounter's burn will change, so stop tracking.
			if (result.ClosestApproachInside)
				result.ClosestApproachLocked = true;
			return;
		}
		{
			result.ClosestApproachInside = dominant == w || ephemeris.IsAncestorOf(w, dominant);
			result.HasClosestApproach = true;
			result.ClosestApproachDistance = d;
			result.ClosestApproachTime = time;
			result.ClosestApproachRelPosition = rel;
			result.ClosestApproachRelVelocity = vel - bodyVel[w];
		}
	}

	private static void RecordSphereChange(Ephemeris ephemeris, PredictionResult result, int from, int to, double time,
		Vector2D pos, Vector2D vel)
	{
		bool entering = to >= 0 && (from < 0 || ephemeris.IsAncestorOf(from, to));
		bool leaving = from >= 0 && (to < 0 || ephemeris.IsAncestorOf(to, from));
		if (!entering && !leaving)
		{
			// Jumped directly between siblings (overlapping spheres).
			entering = to >= 0;
			leaving = from >= 0;
		}
		if (leaving)
		{
			result.Events.Add(new PredictionEvent
			{
				Type = PredictionEventType.SphereExit, Time = time, Body = from, Position = pos, Velocity = vel,
			});
		}
		if (entering)
		{
			result.Events.Add(new PredictionEvent
			{
				Type = PredictionEventType.SphereEnter, Time = time, Body = to, Position = pos, Velocity = vel,
			});
		}
	}
}
