package app.hibiki.reader;

import android.content.Intent;
import android.os.Build;
import android.provider.Settings;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

public class FloatingDictTile extends TileService {

    @Override
    public void onStartListening() {
        super.onStartListening();
        updateTileState();
    }

    @Override
    public void onClick() {
        super.onClick();
        boolean isRunning = FloatingDictService.getInstance() != null;
        if (isRunning) {
            stopService(new Intent(this, FloatingDictService.class));
        } else {
            if (!Settings.canDrawOverlays(this)) {
                Intent intent = new Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        android.net.Uri.parse("package:" + getPackageName()));
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                startActivity(intent);
                return;
            }
            Intent svc = new Intent(this, FloatingDictService.class);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(svc);
            } else {
                startService(svc);
            }
        }
        updateTileState();
    }

    private void updateTileState() {
        Tile tile = getQsTile();
        if (tile == null) return;
        boolean isRunning = FloatingDictService.getInstance() != null;
        tile.setState(isRunning ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
        tile.setLabel("Dictionary");
        tile.updateTile();
    }
}
