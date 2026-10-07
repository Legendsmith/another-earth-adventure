using System;
using Godot;

namespace AnotherEarth.Orbital;

/// <summary>
/// A planet, moon or star moving on rails (Keplerian orbit around its parent body).
/// <para>Gravity is provided by Godot's physics engine: the body creates a child Area2D with point gravity
/// (inverse-square falloff, gravity = mu / r^2) combined with any other overlapping wells. Ships are plain
/// RigidBody2D nodes and need no custom gravity code.</para>
/// <para>The orbit parent is the nearest CelestialBody ancestor in the scene tree unless <see cref="OrbitParentPath"/> is set.</para>
/// </summary>
[Tool]
[GlobalClass]
public partial class CelestialBody : AnimatableBody2D
{
	public const string GroupName = "celestial_bodies";
	/// <summary>Range used for "unlimited" gravity wells and root spheres of influence (covers the whole system).</summary>
	public const double UnlimitedRadius = 1.0e7;

	[ExportGroup("Physical")]
	/// <summary>Gravitational parameter G*M in px^3/s^2. Surface gravity is Mu / Radius^2.</summary>
	[Export] public double Mu { get; set; } = 1.0e6;
	[Export] public double Radius { get; set; } = 100.0;
	/// <summary>Sphere of influence, where this body dominates (reference frame for planning and orbit drawing).
	/// 0 = Laplace sphere a*(m/M)^(2/5), or the whole system for a root body.</summary>
	[Export] public double SphereOfInfluence { get; set; }
	/// <summary>Range of the gravity Area2D. 0 = the sphere of influence (unlimited for a root body).
	/// Bodies move on rails under their parent's gravity only, so limiting each well to its sphere keeps ships
	/// in the same field as the body they orbit; the planner accounts for the truncated well exactly.</summary>
	[Export] public double GravityRange { get; set; }
	[Export(PropertyHint.Layers2DPhysics)] public uint GravityMask { get; set; } = uint.MaxValue;

	[ExportGroup("Orbit")]
	/// <summary>Derive a circular orbit from where the body is placed relative to its parent.</summary>
	[Export] public bool OrbitFromPlacement { get; set; } = true;
	[Export] public double SemiMajorAxis { get; set; }
	[Export(PropertyHint.Range, "0,0.99,0.001")] public double Eccentricity { get; set; }
	[Export(PropertyHint.Range, "-180,180,0.1,degrees")] public double ArgumentOfPeriapsis { get; set; }
	[Export(PropertyHint.Range, "-180,180,0.1,degrees")] public double MeanAnomalyAtEpoch { get; set; }
	/// <summary>Prograde is positive angular momentum, which appears clockwise on screen.</summary>
	[Export] public bool Retrograde { get; set; }
	[Export] public NodePath OrbitParentPath { get; set; } = new();

	[ExportGroup("Visual")]
	[Export] public Color BodyColor { get; set; } = new(0.55f, 0.7f, 1.0f);
	[Export] public bool DrawInfluence { get; set; } = true;

	/// <summary>Index in the current ephemeris, or -1 when not registered.</summary>
	public int BodyIndex { get; internal set; } = -1;
	public double EffectiveSphereOfInfluence { get; private set; }

	internal bool PlacementResolved;
	internal Vector2D FixedPosition;

	private Area2D _gravityWell;
	private CollisionShape2D _wellShape;

	public override void _EnterTree()
	{
		AddToGroup(GroupName);
		if (Engine.IsEditorHint())
			return;
		SyncToPhysics = false; // Positions are set directly by the OrbitalSystem every physics tick.
		(GetTree().GetFirstNodeInGroup(OrbitalSystem.GroupName) as OrbitalSystem)?.MarkDirty();
	}

	public override void _ExitTree()
	{
		if (Engine.IsEditorHint())
			return;
		(GetTree().GetFirstNodeInGroup(OrbitalSystem.GroupName) as OrbitalSystem)?.MarkDirty();
	}

	public override void _Ready()
	{
		QueueRedraw();
	}

	public CelestialBody ResolveOrbitParent()
	{
		if (OrbitParentPath != null && !OrbitParentPath.IsEmpty)
			return GetNodeOrNull<CelestialBody>(OrbitParentPath);
		for (Node n = GetParent(); n != null; n = n.GetParent())
		{
			if (n is CelestialBody body)
				return body;
		}
		return null;
	}

	internal KeplerElements GetElements() => new()
	{
		SemiMajorAxis = SemiMajorAxis,
		Eccentricity = Eccentricity,
		ArgumentOfPeriapsis = Mathf.DegToRad(ArgumentOfPeriapsis),
		MeanAnomalyAtEpoch = Mathf.DegToRad(MeanAnomalyAtEpoch),
		Retrograde = Retrograde,
	};

	internal void SetElements(KeplerElements elements)
	{
		SemiMajorAxis = elements.SemiMajorAxis;
		Eccentricity = elements.Eccentricity;
		ArgumentOfPeriapsis = Mathf.RadToDeg(elements.ArgumentOfPeriapsis);
		MeanAnomalyAtEpoch = Mathf.RadToDeg(Math.IEEERemainder(elements.MeanAnomalyAtEpoch, 2.0 * Math.PI));
		Retrograde = elements.Retrograde;
	}

	/// <summary>Creates/updates the collision shape and the point-gravity Area2D.</summary>
	internal void ConfigurePhysics(double gravityRadius, double sphereOfInfluence)
	{
		EffectiveSphereOfInfluence = sphereOfInfluence;

		CollisionShape2D surface = null;
		foreach (Node child in GetChildren())
		{
			if (child is CollisionShape2D shape)
			{
				surface = shape;
				break;
			}
		}
		if (surface == null)
		{
			surface = new CollisionShape2D { Name = "Surface" };
			AddChild(surface);
		}
		surface.Shape = new CircleShape2D { Radius = (float)Radius };

		if (_gravityWell == null)
		{
			_gravityWell = new Area2D { Name = "GravityWell", Monitorable = false, CollisionLayer = 0 };
			_wellShape = new CollisionShape2D { Name = "Influence" };
			_gravityWell.AddChild(_wellShape);
			AddChild(_gravityWell);
		}
		_gravityWell.CollisionMask = GravityMask;
		_gravityWell.GravitySpaceOverride = Area2D.SpaceOverride.Combine;
		_gravityWell.GravityPoint = true;
		_gravityWell.GravityPointCenter = Vector2.Zero;
		// Godot point gravity: g(d) = gravity * (unit_distance / d)^2  ==  Mu / d^2
		_gravityWell.GravityPointUnitDistance = (float)Radius;
		_gravityWell.Gravity = (float)(Mu / (Radius * Radius));
		_wellShape.Shape = new CircleShape2D { Radius = (float)gravityRadius };
		QueueRedraw();
	}

	public override void _Draw()
	{
		DrawCircle(Vector2.Zero, (float)Radius, BodyColor);
		if (DrawInfluence && EffectiveSphereOfInfluence > 0.0 && EffectiveSphereOfInfluence < UnlimitedRadius)
		{
			var faded = new Color(BodyColor, 0.25f);
			DrawArc(Vector2.Zero, (float)EffectiveSphereOfInfluence, 0f, Mathf.Tau, 128, faded, -1f);
		}
	}
}
