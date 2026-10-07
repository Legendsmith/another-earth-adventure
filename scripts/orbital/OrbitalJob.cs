using Godot;

namespace AnotherEarth.Orbital;

/// <summary>
/// Handle for a solver running on a worker thread. From GDScript:
/// <code>orbital_system.PredictAsync(pos, vel, {}).connect(&amp;"Completed", _on_prediction)</code>
/// or <c>var result = await Signal(job, &amp;"Completed")</c>. The signal is emitted on the main thread,
/// never before the frame the job was created in has finished its scripts.
/// </summary>
[GlobalClass]
public partial class OrbitalJob : RefCounted
{
	[Signal] public delegate void CompletedEventHandler(Variant result);

	public bool IsDone { get; private set; }
	public Variant Result { get; private set; }

	internal void Complete(Variant result)
	{
		Result = result;
		IsDone = true;
		EmitSignal(SignalName.Completed, result);
	}
}
