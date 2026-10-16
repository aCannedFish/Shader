package local.simpleshader.lighting;

import com.mojang.logging.LogUtils;
import java.util.concurrent.atomic.AtomicLong;
import net.minecraft.client.Minecraft;
import net.minecraftforge.fml.common.Mod;
import org.slf4j.Logger;

/** Schedule bounded render-thread updates independently of OptiFine transforms. */
@Mod("simpleshader_lighting")
public final class CompanionMod {
    static final Logger LOGGER = LogUtils.getLogger();

    public CompanionMod() {
        // Time the queued task was submitted, 0 when none is pending. Leaving a
        // world drops the client's pending tasks, so a task that never ran must
        // not block the scheduler forever; after a second a new one is queued.
        AtomicLong queued = new AtomicLong();
        Thread scheduler = new Thread(() -> {
            while (!Thread.currentThread().isInterrupted()) {
                try {
                    Thread.sleep(16);
                    long now = System.nanoTime();
                    long pending = queued.get();
                    if (pending != 0 && now - pending < 1_000_000_000L || !queued.compareAndSet(pending, now)) {
                        continue;
                    }
                    Minecraft.getInstance().execute(() -> {
                        try {
                            LightingBridge.beginFrame();
                            LightingBridge.bindPrograms();
                        } finally {
                            queued.compareAndSet(now, 0);
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
