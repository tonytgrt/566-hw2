using UnityEngine;

// One material per mode for the renderers under this object (element 0 = normal, 1 = danger).
// DangerMode switches every swapper in the scene together.
public class MaterialSwapper : MonoBehaviour
{
    public Material[] materials;
    private Renderer[] renderers;

    void Awake()
    {
        renderers = GetComponentsInChildren<Renderer>(true);
    }

    public void SwapTo(int index)
    {
        if (materials == null || materials.Length == 0) return;
        if (renderers == null) renderers = GetComponentsInChildren<Renderer>(true);
        Material material = materials[index % materials.Length];
        foreach (Renderer r in renderers) r.sharedMaterial = material;
    }
}
