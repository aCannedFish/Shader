package local.simpleshader.lighting;

import com.mojang.logging.LogUtils;
import net.minecraftforge.event.TickEvent;
import net.minecraftforge.fml.common.Mod;
import org.slf4j.Logger;

/** Update once per real client frame, before rendering, with the GL context current. */
@Mod("simpleshader_lighting")
public final class CompanionMod {
    static final Logger LOGGER = LogUtils.getLogger();

    public CompanionMod() {
        TickEvent.RenderTickEvent.Pre.BUS.addListener(event -> {
            try {
                LightingBridge.beginFrame();
                LightingBridge.bindPrograms();
            } catch (RuntimeException error) {
                LightingBridge.fail(error);
            }
        });
        LOGGER.info("SIMPLE_LIGHTING companion loaded");
    }
}
