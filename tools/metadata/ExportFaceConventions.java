package local.simpleshader.metadata;

import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import java.nio.file.Files;
import java.nio.file.Path;
import net.minecraft.client.renderer.FaceInfo;
import net.minecraft.client.renderer.block.model.BlockElementFace;
import net.minecraft.client.renderer.block.model.FaceBakery;
import net.minecraft.core.Direction;
import org.joml.Vector3f;
import org.joml.Vector3fc;

/** Export immutable face winding and UV conventions for the resource compiler.
 * No world, client, texture atlas or graphics context is created.
 */
public final class ExportFaceConventions {
    private ExportFaceConventions() {}

    public static void main(String[] arguments) throws Exception {
        var defaultUv = FaceBakery.class.getDeclaredMethod("defaultFaceUV",
            Vector3fc.class, Vector3fc.class, Direction.class);
        defaultUv.setAccessible(true);
        JsonObject result = new JsonObject();
        for (Direction direction : Direction.values()) {
            JsonObject face = new JsonObject();
            JsonArray corners = new JsonArray();
            for (int vertex = 0; vertex < 4; vertex++) {
                Vector3f point = FaceInfo.fromFacing(direction).getVertexInfo(vertex)
                    .select(new Vector3f(0.0f), new Vector3f(1.0f));
                JsonArray coordinates = new JsonArray();
                coordinates.add(point.x);
                coordinates.add(point.y);
                coordinates.add(point.z);
                corners.add(coordinates);
            }
            face.add("corners", corners);
            var uv = (BlockElementFace.UVs)defaultUv.invoke(null,
                new Vector3f(1, 2, 3), new Vector3f(11, 13, 15), direction);
            JsonObject rotations = new JsonObject();
            for (var quadrant : com.mojang.math.Quadrant.values()) {
                JsonArray coordinates = new JsonArray();
                for (int vertex = 0; vertex < 4; vertex++) {
                    JsonArray point = new JsonArray();
                    point.add(BlockElementFace.getU(uv, quadrant, vertex));
                    point.add(BlockElementFace.getV(uv, quadrant, vertex));
                    coordinates.add(point);
                }
                rotations.add(quadrant.name(), coordinates);
            }
            face.add("uv_rotations", rotations);
            result.add(direction.getName(), face);
        }
        Files.writeString(Path.of(arguments[0]), new GsonBuilder().setPrettyPrinting().create().toJson(result));
    }
}
