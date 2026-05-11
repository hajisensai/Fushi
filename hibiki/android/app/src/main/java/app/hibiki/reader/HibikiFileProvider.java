package app.hibiki.reader;

import android.net.Uri;
import androidx.core.content.FileProvider;

public class HibikiFileProvider extends FileProvider {
    @Override
    public String getType(Uri uri) {
        String lastSegment = uri.getLastPathSegment();
        if (lastSegment != null) {
            int dotIndex = lastSegment.lastIndexOf('.');
            if (dotIndex > 0) {
                String ext = lastSegment.substring(dotIndex + 1).toLowerCase();
                switch (ext) {
                    case "aac": return "audio/aac";
                    case "m4a": return "audio/mp4";
                }
            }
        }
        return super.getType(uri);
    }
}
