using System;
using System.Collections.Generic;

namespace AnotherEarth.Orbital;

/// <summary>Immutable description of one celestial body for the solvers.</summary>
public sealed class BodyDef
{
	public string Name = "";
	/// <summary>Index of the body this one orbits, or -1 for a fixed root body.</summary>
	public int Parent = -1;
	public int Depth;
	/// <summary>Gravitational parameter (G * M) in px^3/s^2.</summary>
	public double Mu;
	public double Radius;
	/// <summary>Sphere of influence: inside it this body is the dominant body (reference frame for planning and drawing).</summary>
	public double SphereOfInfluence;
	/// <summary>Radius of the gravity Area2D. Gravity from this body only applies inside it.</summary>
	public double GravityRadius;
	public KeplerElements Orbit;
	public Vector2D FixedPosition;
}

/// <summary>
/// Immutable snapshot of every body on rails. Thread-safe: all worker jobs share one instance,
/// and the <see cref="OrbitalSystem"/> swaps in a new instance whenever bodies are added or removed.
/// Bodies are ordered so that every parent precedes its children.
/// </summary>
public sealed class Ephemeris
{
	public readonly BodyDef[] Bodies;
	public int Count => Bodies.Length;

	public Ephemeris(BodyDef[] bodies)
	{
		Bodies = bodies;
		for (int i = 0; i < bodies.Length; i++)
		{
			if (bodies[i].Parent >= i)
				throw new ArgumentException("Celestial bodies must be ordered parents first.");
		}
	}

	public double ParentMu(int i) => Bodies[i].Parent >= 0 ? Bodies[Bodies[i].Parent].Mu : 0.0;

	/// <summary>Fills absolute positions and velocities for all bodies at time <paramref name="t"/>.</summary>
	public void ComputeStates(double t, Vector2D[] positions, Vector2D[] velocities)
	{
		for (int i = 0; i < Bodies.Length; i++)
		{
			BodyDef b = Bodies[i];
			if (b.Parent < 0)
			{
				positions[i] = b.FixedPosition;
				velocities[i] = Vector2D.Zero;
				continue;
			}
			b.Orbit.StateAt(t, Bodies[b.Parent].Mu, out Vector2D rel, out Vector2D relVel);
			positions[i] = positions[b.Parent] + rel;
			velocities[i] = velocities[b.Parent] + relVel;
		}
	}

	/// <summary>Absolute state of a single body; only evaluates its ancestor chain.</summary>
	public void GetState(int i, double t, out Vector2D position, out Vector2D velocity)
	{
		position = Vector2D.Zero;
		velocity = Vector2D.Zero;
		while (i >= 0)
		{
			BodyDef b = Bodies[i];
			if (b.Parent < 0)
			{
				position += b.FixedPosition;
				return;
			}
			b.Orbit.StateAt(t, Bodies[b.Parent].Mu, out Vector2D rel, out Vector2D relVel);
			position += rel;
			velocity += relVel;
			i = b.Parent;
		}
	}

	public Vector2D GetPosition(int i, double t)
	{
		GetState(i, t, out Vector2D p, out _);
		return p;
	}

	/// <summary>
	/// The deepest body whose gravity area contains <paramref name="point"/> — the body that dominates the motion there.
	/// Returns -1 when the point is outside every area.
	/// </summary>
	public int FindDominant(Vector2D point, Vector2D[] positions)
	{
		int best = -1;
		int bestDepth = -1;
		for (int i = 0; i < Bodies.Length; i++)
		{
			BodyDef b = Bodies[i];
			if (b.Depth <= bestDepth)
				continue;
			double r = b.SphereOfInfluence;
			if ((point - positions[i]).LengthSquared <= r * r)
			{
				best = i;
				bestDepth = b.Depth;
			}
		}
		return best;
	}

	/// <summary>True if <paramref name="ancestor"/> is a strict ancestor of <paramref name="body"/>.</summary>
	public bool IsAncestorOf(int ancestor, int body)
	{
		if (ancestor < 0 || body < 0)
			return false;
		for (int p = Bodies[body].Parent; p >= 0; p = Bodies[p].Parent)
		{
			if (p == ancestor)
				return true;
		}
		return false;
	}

	public int CommonAncestor(int a, int b)
	{
		if (a < 0 || b < 0)
			return -1;
		var chain = new HashSet<int>();
		for (int p = a; p >= 0; p = Bodies[p].Parent)
			chain.Add(p);
		for (int p = b; p >= 0; p = Bodies[p].Parent)
		{
			if (chain.Contains(p))
				return p;
		}
		return -1;
	}

	/// <summary>The child of <paramref name="ancestor"/> on the path down to <paramref name="descendant"/>.</summary>
	public int ChildToward(int ancestor, int descendant)
	{
		int current = descendant;
		while (current >= 0 && Bodies[current].Parent != ancestor)
			current = Bodies[current].Parent;
		return current;
	}

	public IEnumerable<int> ChildrenOf(int parent)
	{
		for (int i = 0; i < Bodies.Length; i++)
		{
			if (Bodies[i].Parent == parent)
				yield return i;
		}
	}

	/// <summary>Orbital radius used for planning estimates (semi-major axis around the parent).</summary>
	public double OrbitRadius(int i) => Bodies[i].Parent >= 0 ? Bodies[i].Orbit.SemiMajorAxis : 0.0;

	public double OrbitPeriod(int i) => Bodies[i].Parent >= 0 ? Bodies[i].Orbit.Period(ParentMu(i)) : double.PositiveInfinity;
}

/// <summary>
/// Pre-computed body states on the physics tick grid. Repeated predictions over the same window
/// (e.g. the Newton iterations of the targeting solver) look states up instead of re-solving Kepler's equation.
/// </summary>
public sealed class EphemerisTable
{
	public readonly double StartTime;
	public readonly double Dt;
	public readonly int Steps;
	public readonly int BodyCount;
	private readonly Vector2D[] _positions;
	private readonly Vector2D[] _velocities;

	public EphemerisTable(Ephemeris ephemeris, double startTime, double dt, int steps)
	{
		StartTime = startTime;
		Dt = dt;
		Steps = Math.Max(steps, 1);
		BodyCount = ephemeris.Count;
		_positions = new Vector2D[Steps * BodyCount];
		_velocities = new Vector2D[Steps * BodyCount];
		var p = new Vector2D[BodyCount];
		var v = new Vector2D[BodyCount];
		for (int k = 0; k < Steps; k++)
		{
			ephemeris.ComputeStates(startTime + k * dt, p, v);
			Array.Copy(p, 0, _positions, k * BodyCount, BodyCount);
			Array.Copy(v, 0, _velocities, k * BodyCount, BodyCount);
		}
	}

	/// <summary>Copies the states of tick <paramref name="step"/> into the buffers. Returns false if out of range.</summary>
	public bool TryCopy(int step, Vector2D[] positions, Vector2D[] velocities)
	{
		if (step < 0 || step >= Steps)
			return false;
		Array.Copy(_positions, step * BodyCount, positions, 0, BodyCount);
		Array.Copy(_velocities, step * BodyCount, velocities, 0, BodyCount);
		return true;
	}
}
