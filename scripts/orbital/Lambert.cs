using System;

namespace AnotherEarth.Orbital;

/// <summary>
/// Universal-variable Lambert solver (Vallado, algorithm 58) for zero-revolution transfers.
/// Given two positions and a time of flight around a central body it returns the
/// velocities required at departure and arrival.
/// </summary>
public static class Lambert
{
	private const int MaxIterations = 100;

	public static bool Solve(Vector2D r1, Vector2D r2, double timeOfFlight, double mu, bool retrograde,
		out Vector2D v1, out Vector2D v2)
	{
		v1 = Vector2D.Zero;
		v2 = Vector2D.Zero;
		double r1n = r1.Length, r2n = r2.Length;
		if (timeOfFlight <= 0.0 || r1n <= 0.0 || r2n <= 0.0 || mu <= 0.0)
			return false;

		double cosDnu = Math.Clamp(r1.Dot(r2) / (r1n * r2n), -1.0, 1.0);
		if (1.0 - cosDnu < 1e-10)
			return false; // Positions are colinear in the same direction: transfer plane is undefined.
		double dnu = Math.Acos(cosDnu);
		double cross = r1.Cross(r2);
		bool longWay = retrograde ? cross > 0.0 : cross < 0.0;
		if (longWay)
			dnu = 2.0 * Math.PI - dnu;

		double a = Math.Sin(dnu) * Math.Sqrt(r1n * r2n / (1.0 - cosDnu));
		if (Math.Abs(a) < 1e-9)
			return false; // 180 degree transfer is singular for this formulation.

		double sqrtMu = Math.Sqrt(mu);
		double zLow = -4.0 * Math.PI * Math.PI;
		double zHigh = 4.0 * Math.PI * Math.PI;
		double z = 0.0, y = 0.0, t = double.NaN;

		// Time of flight increases monotonically with z, so bisection is robust.
		for (int i = 0; i < MaxIterations; i++)
		{
			z = 0.5 * (zLow + zHigh);
			Stumpff(z, out double c2, out double c3);
			y = r1n + r2n + a * (z * c3 - 1.0) / Math.Sqrt(c2);
			if (a > 0.0 && y < 0.0)
			{
				zLow = z;
				continue;
			}
			double x = Math.Sqrt(y / c2);
			t = (x * x * x * c3 + a * Math.Sqrt(y)) / sqrtMu;
			if (Math.Abs(t - timeOfFlight) < 1e-10 * timeOfFlight)
				break;
			if (t <= timeOfFlight)
				zLow = z;
			else
				zHigh = z;
		}
		if (y <= 0.0 || !(Math.Abs(t - timeOfFlight) < 1e-6 * timeOfFlight))
			return false;

		double f = 1.0 - y / r1n;
		double g = a * Math.Sqrt(y / mu);
		double gDot = 1.0 - y / r2n;
		v1 = (r2 - r1 * f) / g;
		v2 = (r2 * gDot - r1) / g;
		return v1.IsFinite && v2.IsFinite;
	}

	private static void Stumpff(double z, out double c2, out double c3)
	{
		if (z > 1e-6)
		{
			double s = Math.Sqrt(z);
			c2 = (1.0 - Math.Cos(s)) / z;
			c3 = (s - Math.Sin(s)) / (s * s * s);
		}
		else if (z < -1e-6)
		{
			double s = Math.Sqrt(-z);
			c2 = (Math.Cosh(s) - 1.0) / -z;
			c3 = (Math.Sinh(s) - s) / (s * s * s);
		}
		else
		{
			c2 = 0.5 - z / 24.0;
			c3 = 1.0 / 6.0 - z / 120.0;
		}
	}
}
