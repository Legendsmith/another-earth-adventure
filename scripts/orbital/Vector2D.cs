using System;
using Godot;

namespace AnotherEarth.Orbital;

/// <summary>
/// Double precision 2D vector used by the orbital solvers. Godot's Vector2 is single precision,
/// which is not enough for long trajectory integrations or Lambert solutions.
/// </summary>
public readonly struct Vector2D : IEquatable<Vector2D>
{
	public readonly double X;
	public readonly double Y;

	public static readonly Vector2D Zero = new(0.0, 0.0);

	public Vector2D(double x, double y)
	{
		X = x;
		Y = y;
	}

	public double LengthSquared => X * X + Y * Y;
	public double Length => Math.Sqrt(X * X + Y * Y);

	/// <summary>Angle from the +X axis, in radians.</summary>
	public double Angle => Math.Atan2(Y, X);

	/// <summary>This vector rotated by +90 degrees (the direction of motion for positive angular momentum).</summary>
	public Vector2D Perpendicular => new(-Y, X);

	public double Dot(Vector2D o) => X * o.X + Y * o.Y;

	/// <summary>Z component of the 3D cross product. Positive means <paramref name="o"/> is rotated positively from this vector.</summary>
	public double Cross(Vector2D o) => X * o.Y - Y * o.X;

	public Vector2D Normalized()
	{
		double l = Length;
		return l > 0.0 ? new Vector2D(X / l, Y / l) : Zero;
	}

	public Vector2D Rotated(double angle)
	{
		double c = Math.Cos(angle), s = Math.Sin(angle);
		return new Vector2D(X * c - Y * s, X * s + Y * c);
	}

	public static Vector2D FromAngle(double angle) => new(Math.Cos(angle), Math.Sin(angle));

	public bool IsFinite => double.IsFinite(X) && double.IsFinite(Y);

	public Vector2 ToVector2() => new((float)X, (float)Y);

	public static implicit operator Vector2D(Vector2 v) => new(v.X, v.Y);

	public static Vector2D operator +(Vector2D a, Vector2D b) => new(a.X + b.X, a.Y + b.Y);
	public static Vector2D operator -(Vector2D a, Vector2D b) => new(a.X - b.X, a.Y - b.Y);
	public static Vector2D operator -(Vector2D a) => new(-a.X, -a.Y);
	public static Vector2D operator *(Vector2D a, double s) => new(a.X * s, a.Y * s);
	public static Vector2D operator *(double s, Vector2D a) => new(a.X * s, a.Y * s);
	public static Vector2D operator /(Vector2D a, double s) => new(a.X / s, a.Y / s);

	public bool Equals(Vector2D other) => X == other.X && Y == other.Y;
	public override bool Equals(object obj) => obj is Vector2D other && Equals(other);
	public override int GetHashCode() => HashCode.Combine(X, Y);
	public override string ToString() => $"({X:0.###}, {Y:0.###})";
}
