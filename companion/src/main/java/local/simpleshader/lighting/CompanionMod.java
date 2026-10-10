package local.simpleshader.lighting;

import com.mojang.logging.LogUtils;
import java.util.concurrent.atomic.AtomicBoolean;
import net.minecraft.client.Minecraft;
import net.minecraftforge.fml.common.Mod;
import org.slf4j.Logger;

/** Schedule bounded render-thread updates independently of OptiFine transforms. */
@Mod("simpleshader_lighting")
public final class CompanionMod {
    static final Logger LOGGER = LogUtils.getLogger();

    public CompanionMod() {
        AtomicBoolean queued = new AtomicBoolean();
        Thread scheduler = new Thread(() -> {
            while (!Thread.currentThread().isInterrupted()) {
                try {
                    Thread.sleep(16);
                    if (!queued.compareAndSet(false, true)) {
                        continue;
                    }
                    Minecraft.getInstance().execute(() -> {
                        try {
                            LightingBridge.beginFrame();
                            LightingBridge.bindPrograms();
                        } finally {
                            queued.set(false);
                        }
                    });
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                }
            }
        }, "SimpleShader local lighting");
        scheduler.setDaemon(true);
        scheduler.start();
        LOGGER.info("SIMPLE_LIGHTING companion loaded");
    }
}
