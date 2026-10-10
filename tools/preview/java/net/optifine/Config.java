package net.optifine;

import java.util.ArrayList;
import java.util.StringTokenizer;

/**
 * Pure parsing helpers required by OptiFine's offline compatibility transform.
 * This bridge replaces Config only in the converter subprocess; it is never
 * added to Minecraft's classpath and does not implement renderer behavior.
 */
public final class Config {
    private Config() {
    }

    public static int parseInt(String text, int fallback) {
        try {
            return Integer.parseInt(text.trim());
        } catch (NumberFormatException invalid) {
            return fallback;
        }
    }

    public static String[] tokenize(String text, String delimiters) {
        ArrayList<String> result = new ArrayList<>();
        StringTokenizer tokenizer = new StringTokenizer(text, delimiters);
        while (tokenizer.hasMoreTokens()) {
            result.add(tokenizer.nextToken());
        }
        return result.toArray(new String[0]);
    }

    public static void warn(String message) {
        System.err.println(message);
    }
}
