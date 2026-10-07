using System;
using Godot;
using Godot.Collections;

namespace AnotherEarth.Orbital;

/// <summary>
/// GDScript-facing wrapper around a <see cref="PredictionResult"/>.
/// Path points are split into segments by dominant body so they can be drawn KSP-style:
/// the segment around the starting body follows that body, encounter segments are drawn around the
/// body's "ghost" at closest approach, and segments around a fixed root body are absolute.
/// </summary>
[GlobalClass]
public partial class TrajectoryPrediction : RefCounted
{
	internal PredictionResult Result;
	internal Ephemeris Ephemeris;
	private Array<Dictionary> _segments;
	private int[] _segmentStarts = System.Array.Empty<int>();

	public double StartTime => Result?.StartTime ?? 0.0;
	public double EndTime => Result?.FinalTime ?? 0.0;
	public string EndReason => Result?.EndReason ?? "";
	public int InitialBody => Result?.InitialDominant ?? -1;
	public Vector2 FinalPosition => Result?.FinalPosition.ToVector2() ?? Vector2.Zero;
	public Vector2 FinalVelocity => Result?.FinalVelocity.ToVector2() ?? Vector2.Zero;
	public int SampleCount => Result?.Times.Count ?? 0;

	internal static TrajectoryPrediction Create(PredictionResult result, Ephemeris ephemeris) =>
		new() { Result = result, Ephemeris = ephemeris };

	/// <summary>All sampled positions in world space at their own sample times.</summary>
	public Vector2[] GetWorldPoints()
	{
		var points = new Vector2[Result.Positions.Count];
		for (int i = 0; i < points.Length; i++)
			points[i] = Result.Positions[i].ToVector2();
		return points;
	}

	/// <summary>
	/// Array of {body, follows_body, anchor, anchor_time, ghost, points, velocities, times, start_time, end_time}
	/// (points and velocities are relative to the segment's body).
	/// Draw each segment's points offset by the body's current position when follows_body is true,
	/// otherwise offset by anchor (a world position).
	/// </summary>
	public Array<Dictionary> BuildPathSegments()
	{
		if (_segments != null)
			return _segments;
		_segments = new Array<Dictionary>();
		int count = Result.Times.Count;
		var starts = new System.Collections.Generic.List<int>();
		int runStart = 0;
		for (int i = 1; i <= count; i++)
		{
			if (i == count || Result.Dominant[i] != Result.Dominant[runStart])
			{
				starts.Add(runStart);
				_segments.Add(BuildSegment(runStart, i));
				runStart = i;
			}
		}
		_segmentStarts = starts.ToArray();
		return _segments;
	}

	private Dictionary BuildSegment(int start, int end)
	{
		int body = Result.Dominant[start];
		int count = Result.Times.Count;
		int last = Math.Min(end, count - 1); // Include the first point of the next run so segments join up.
		var rel = new Vector2[last - start + 1];
		var relVelocities = new Vector2[last - start + 1];
		var times = new double[last - start + 1];
		double anchorTime = Result.Times[start];
		double minDistance = double.PositiveInfinity;
		for (int i = start; i <= last; i++)
		{
			Vector2D p = Result.Positions[i];
			Vector2D bodyPos = Vector2D.Zero, bodyVel = Vector2D.Zero;
			if (body >= 0)
				Ephemeris.GetState(body, Result.Times[i], out bodyPos, out bodyVel);
			Vector2D r = p - bodyPos;
			rel[i - start] = r.ToVector2();
			relVelocities[i - start] = (Result.Velocities[i] - bodyVel).ToVector2();
			times[i - start] = Result.Times[i];
			if (i < end && r.LengthSquared < minDistance)
			{
				minDistance = r.LengthSquared;
				anchorTime = Result.Times[i];
			}
		}
		bool follows = body >= 0 && body == Result.InitialDominant;
		bool moving = body >= 0 && Ephemeris.Bodies[body].Parent >= 0;
		Vector2 anchor = body >= 0 ? Ephemeris.GetPosition(body, anchorTime).ToVector2() : Vector2.Zero;
		return new Dictionary
		{
			{ "body", body },
			{ "follows_body", follows },
			{ "anchor", anchor },
			{ "anchor_time", anchorTime },
			{ "ghost", moving && !follows },
			{ "points", rel },
			{ "velocities", relVelocities },
			{ "times", times },
			{ "start_time", Result.Times[start] },
			{ "end_time", Result.Times[last] },
		};
	}

	private int SegmentIndexAt(double time)
	{
		BuildPathSegments();
		int index = 0;
		for (int s = 0; s < _segmentStarts.Length; s++)
		{
			if (Result.Times[_segmentStarts[s]] <= time)
				index = s;
		}
		return index;
	}

	/// <summary>
	/// Array of {type, time, body, distance, position (world at event time), segment, local_position}.
	/// local_position is relative to the segment's frame, for drawing alongside BuildPathSegments().
	/// </summary>
	public Array<Dictionary> GetEvents()
	{
		var events = new Array<Dictionary>();
		var segments = BuildPathSegments();
		foreach (PredictionEvent e in Result.Events)
		{
			int segment = SegmentIndexAt(e.Time);
			int frameBody = segments.Count > 0 ? (int)segments[segment]["body"] : -1;
			Vector2D local = frameBody >= 0 ? e.Position - Ephemeris.GetPosition(frameBody, e.Time) : e.Position;
			events.Add(new Dictionary
			{
				{ "type", EventName(e.Type) },
				{ "time", e.Time },
				{ "body", e.Body },
				{ "distance", e.Distance },
				{ "position", e.Position.ToVector2() },
				{ "segment", segment },
				{ "local_position", local.ToVector2() },
			});
		}
		return events;
	}

	/// <summary>{found, body, time, distance, signed_distance, relative_position, relative_velocity}.</summary>
	public Dictionary GetClosestApproach()
	{
		return new Dictionary
		{
			{ "found", Result.HasClosestApproach },
			{ "time", Result.ClosestApproachTime },
			{ "distance", Result.ClosestApproachDistance },
			{ "signed_distance", Result.HasClosestApproach ? Result.ClosestApproachSigned : 0.0 },
			{ "relative_position", Result.ClosestApproachRelPosition.ToVector2() },
			{ "relative_velocity", Result.ClosestApproachRelVelocity.ToVector2() },
		};
	}

	public static string EventName(PredictionEventType type) => type switch
	{
		PredictionEventType.SphereEnter => "sphere_enter",
		PredictionEventType.SphereExit => "sphere_exit",
		PredictionEventType.Periapsis => "periapsis",
		PredictionEventType.Apoapsis => "apoapsis",
		PredictionEventType.Burn => "burn",
		PredictionEventType.Collision => "collision",
		PredictionEventType.ClosestApproach => "closest_approach",
		_ => "unknown",
	};
}
