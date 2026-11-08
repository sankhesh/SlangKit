module broken_hooks;
import slangkit_hooks;
public struct Broken : IShaderHooks {
  public override void lit(inout FragmentContext f) { f.color.rgb *= undefinedAmount; }
};
