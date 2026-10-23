package local.simpleshader.metadata;

import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import com.mojang.math.Quadrant;
import java.nio.file.Files;
import java.nio.file.Path;
import net.minecraft.client.renderer.FaceInfo;
import net.minecraft.client.resources.model.BlockModelRotation;
import net.minecraft.core.Direction;
import org.joml.Vector3f;

/** Export immutable UV-lock reference transforms through the matching engine.
 * No registry bootstrap, client, world or graphics context is needed.
 */
public final class ExportUvLock {
    private ExportUvLock() {}

    public static void main(String[] arguments) throws Exception {
        JsonArray result = new JsonArray();
        float[][] probes = {{0,0},{0,1},{1,1},{1,0},{.2f,.7f},{.8f,.3f}};
        for (Quadrant x : Quadrant.values()) {
            for (Quadrant y : Quadrant.values()) {
                var state = BlockModelRotation.get(Quadrant.fromXYAngles(x,y)).withUvLock();
                for (Direction face : Direction.values()) {
                    JsonObject entry = new JsonObject();
                    entry.addProperty("x",x.shift*90);
                    entry.addProperty("y",y.shift*90);
                    entry.addProperty("face",face.getName());
                    JsonArray values = new JsonArray();
                    for (float[] probe : probes) {
                        Vector3f point = new Vector3f(probe[0]-.5f,probe[1]-.5f,0);
                        state.inverseFaceTransformation(face).transformPosition(point);
                        JsonArray value = new JsonArray();
                        value.add(point.x+.5f);
                        value.add(point.y+.5f);
                        values.add(value);
                    }
                    entry.add("uv",values);
                    JsonArray positions = new JsonArray();
                    for (int vertex=0;vertex<4;vertex++) {
                        Vector3f point = FaceInfo.fromFacing(face).getVertexInfo(vertex)
                            .select(new Vector3f(0),new Vector3f(1));
                        point.sub(.5f,.5f,.5f);
                        state.transformation().getMatrix().transformPosition(point);
                        point.add(.5f,.5f,.5f);
                        JsonArray value = new JsonArray();
                        value.add(point.x);
                        value.add(point.y);
                        value.add(point.z);
                        positions.add(value);
                    }
                    entry.add("positions",positions);
                    result.add(entry);
                }
            }
        }
        Files.writeString(Path.of(arguments[0]),new GsonBuilder().setPrettyPrinting().create().toJson(result));
    }
}
