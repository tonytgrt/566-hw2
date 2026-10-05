using UnityEngine;
using UnityEngine.Rendering.Universal;

// Part 6: the key (Space) toggles "DANGER" mode, after Resident Evil's health status screen. Every MaterialSwapper
// switches to its danger material, and the Horror Post full-screen pass hands over to the Danger Post pass.
public class DangerMode : MonoBehaviour
{
    public KeyCode key = KeyCode.Space;
    public ScriptableRendererFeature calmPost;
    public ScriptableRendererFeature dangerPost;

    private bool danger;

    void Start()
    {
        Apply(false);
    }

    void Update()
    {
        if (Input.GetKeyDown(key)) Apply(!danger);
    }

    public void Apply(bool on)
    {
        danger = on;
        foreach (MaterialSwapper swapper in FindObjectsOfType<MaterialSwapper>()) swapper.SwapTo(on ? 1 : 0);
        if (calmPost) calmPost.SetActive(!on);
        if (dangerPost) dangerPost.SetActive(on);
    }

    // The renderer features are project assets, so leave them in calm mode when play mode ends.
    void OnDisable()
    {
        if (calmPost) calmPost.SetActive(true);
        if (dangerPost) dangerPost.SetActive(false);
    }
}
