using System;

namespace AnotherEarth.Orbital;

/// <summary>
/// Classical 2D orbital elements for a body on rails around its parent.
/// "Prograde" means positive angular momentum (X x Y), which appears clockwise on screen because Godot's Y axis points down.
/// </summary>
public struct KeplerElements
{
	public double SemiMajorAxis;
	public double Eccentricity;
	/// <summary>Radians, measured from the +X axis.</summary>
	public double ArgumentOfPeriapsis;
	/// <summary>Mean anomaly at simulation time 0, radians.</summary>
	public double MeanAnomalyAtEpoch;
	public bool Retrograde;

	public double MeanMotion(double mu) => Math.Sqrt(mu / (SemiMajorAxis * SemiMajorAxis * SemiMajorAxis));

	public double Period(double mu) => 2.0 * Math.PI / MeanMotion(mu);

	/// <summary>Position and velocity relative to the parent body at time <paramref name="t"/>.</summary>
	public void StateAt(double t, double mu, out Vector2D position, out Vector2D velocity)
	{
		double a = SemiMajorAxis;
		double e = Eccentricity;
		double n = MeanMotion(mu);
		double eAnomaly = SolveKepler(MeanAnomalyAtEpoch + n * t, e);
		double cosE = Math.Cos(eAnomaly), sinE = Math.Sin(eAnomaly);
		double b = a * Math.Sqrt(1.0 - e * e);
		double eDot = n / (1.0 - e * cosE);

		double x = a * (cosE - e);
		double y = b * sinE;
		double vx = -a * sinE * eDot;
		double vy = b * cosE * eDot;
		if (Retrograde)
		{
			y = -y;
			vy = -vy;
		}
		position = new Vector2D(x, y).Rotated(ArgumentOfPeriapsis);
		velocity = new Vector2D(vx, vy).Rotated(ArgumentOfPeriapsis);
	}

	/// <summary>Solves Kepler's equation M = E - e sin E for elliptic orbits.</summary>
	public static double SolveKepler(double meanAnomaly, double e)
	{
		double m = Math.IEEERemainder(meanAnomaly, 2.0 * Math.PI);
		double eAnomaly = e < 0.8 ? m : Math.PI * Math.Sign(m == 0.0 ? 1.0 : m);
		for (int i = 0; i < 30; i++)
		{
			double f = eAnomaly - e * Math.Sin(eAnomaly) - m;
			double step = f / (1.0 - e * Math.Cos(eAnomaly));
			eAnomaly -= step;
			if (Math.Abs(step) < 1e-12)
				break;
		}
		return eAnomaly;
	}

	/// <summary>A circular orbit passing through <paramref name="relativePosition"/> at time <paramref name="time"/>.</summary>
	public static KeplerElements Circular(Vector2D relativePosition, double mu, double time, bool retrograde)
	{
		var elements = new KeplerElements
		{
			SemiMajorAxis = relativePosition.Length,
			Eccentricity = 0.0,
			ArgumentOfPeriapsis = 0.0,
			Retrograde = retrograde,
		};
		double angle = relativePosition.Angle;
		// Retrograde orbits mirror Y before rotation, so the anomaly runs the other way.
		double anomalyNow = retrograde ? -angle : angle;
		elements.MeanAnomalyAtEpoch = anomalyNow - elements.MeanMotion(mu) * time;
		return elements;
	}
}

/// <summary>Osculating (instantaneous two-body) orbit of a free body, used for HUD readouts and planning.</summary>
public struct OrbitInfo
{
	public double SemiMajorAxis;
	public double Eccentricity;
	public double Periapsis;
	/// <summary>Infinity for escape trajectories.</summary>
	public double Apoapsis;
	public double Period;
	public double ArgumentOfPeriapsis;
	public double AngularMomentum;
	public double SpecificEnergy;
	public bool Bound;

	public static OrbitInfo FromState(Vector2D r, Vector2D v, double mu)
	{
		double rLen = r.Length;
		double h = r.Cross(v);
		double energy = 0.5 * v.LengthSquared - mu / rLen;
		Vector2D eVec = (r * (v.LengthSquared - mu / rLen) - v * r.Dot(v)) / mu;
		double e = eVec.Length;
		var info = new OrbitInfo
		{
			Eccentricity = e,
			AngularMomentum = h,
			SpecificEnergy = energy,
			Bound = energy < 0.0,
			Periapsis = h * h / mu / (1.0 + e),
			ArgumentOfPeriapsis = e > 1e-9 ? eVec.Angle : r.Angle,
		};
		if (info.Bound)
		{
			info.SemiMajorAxis = -mu / (2.0 * energy);
			info.Apoapsis = info.SemiMajorAxis * (1.0 + e);
			info.Period = 2.0 * Math.PI * Math.Sqrt(Math.Pow(info.SemiMajorAxis, 3) / mu);
		}
		else
		{
			info.SemiMajorAxis = energy != 0.0 ? -mu / (2.0 * energy) : double.PositiveInfinity;
			info.Apoapsis = double.PositiveInfinity;
			info.Period = double.PositiveInfinity;
		}
		return info;
	}
}
