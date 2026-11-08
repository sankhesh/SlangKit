module good_hooks;
import slangkit_hooks;
public struct Halve : IShaderHooks {
  [Range(0, 1)] [Label("Amount")] float amount;
  public override void lit(inout FragmentContext f) { f.color.rgb *= amount; }
};
