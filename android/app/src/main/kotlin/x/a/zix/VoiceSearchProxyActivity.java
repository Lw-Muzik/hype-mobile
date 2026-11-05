package x.a.zix;

import android.app.Activity;
import android.app.SearchManager;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.net.Uri;
import android.os.Bundle;

import java.util.ArrayList;
import java.util.List;

/**
 * Catches the voice-search request the system sends when a headset's play/pause
 * or hook button is held, which never reaches an app as a key event.
 *
 * <p>Disabled in the manifest and enabled only while the settings call for it
 * (see {@link MediaButtonBridge#setPolicy}). A request that comes from the
 * system itself, with no query, while Hype plays, on an output whose button
 * mode wants the long press, is the long press. Any other
 * request is handed on to the other voice-search apps, so enabling this never
 * takes voice search away from them. Imports only android.* and java.*.
 */
public class VoiceSearchProxyActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        try {
            final Intent request = getIntent();
            if (request != null && isLongPress(request)
                    && MediaButtonBridge.onVoiceLongPress(getApplicationContext())) {
                // Handled by Hype.
            } else if (request != null) {
                // Not a long press, or Hype cannot act on it right now: the
                // listener still gets their voice search.
                forward(request);
            }
        } catch (RuntimeException e) {
            // A voice request that cannot be passed on is dropped; never crash a key press.
        } finally {
            finish();
        }
    }

    private boolean isLongPress(Intent request) {
        final Uri referrer = getReferrer();
        final boolean fromSystem = referrer != null && "android".equals(referrer.getHost());
        final String query = request.getStringExtra(SearchManager.QUERY);
        final boolean noQuery = query == null || query.isEmpty();
        return fromSystem
                && noQuery
                && MediaButtonBridge.isPlaying()
                && MediaButtonBridge.wantsLongPress(getApplicationContext());
    }

    /**
     * Hands the request to the other app that handles it: straight to the only
     * one, through a chooser (which leaves this activity out) when there are
     * several, nowhere when there are none. No target is a Hype proxy, so the
     * request cannot come back here.
     */
    private void forward(Intent request) {
        final Intent copy = new Intent(request);
        copy.setComponent(null);
        copy.setPackage(null);
        copy.setSelector(null);

        final PackageManager pm = getPackageManager();
        final List<ResolveInfo> found = pm.queryIntentActivities(copy, PackageManager.MATCH_DEFAULT_ONLY);
        final List<ActivityInfo> others = new ArrayList<>();
        if (found != null) {
            for (ResolveInfo info : found) {
                final ActivityInfo ai = info.activityInfo;
                if (ai == null) continue;
                // Not this app, and not another Hype build's proxy either (a dev
                // copy beside the release one would otherwise pass it back and forth).
                if (getPackageName().equals(ai.packageName)) continue;
                if (VoiceSearchProxyActivity.class.getName().equals(ai.name)) continue;
                others.add(ai);
            }
        }
        if (others.isEmpty()) return;

        try {
            if (others.size() == 1) {
                final ActivityInfo only = others.get(0);
                copy.setComponent(new ComponentName(only.packageName, only.name));
                startActivity(copy);
            } else {
                final Intent chooser = Intent.createChooser(copy, null);
                // This proxy, and any other Hype build's.
                final List<ComponentName> excluded = new ArrayList<>();
                excluded.add(new ComponentName(this, VoiceSearchProxyActivity.class));
                for (ResolveInfo info : found) {
                    final ActivityInfo ai = info.activityInfo;
                    if (ai != null && VoiceSearchProxyActivity.class.getName().equals(ai.name)) {
                        excluded.add(new ComponentName(ai.packageName, ai.name));
                    }
                }
                chooser.putExtra(
                        Intent.EXTRA_EXCLUDE_COMPONENTS,
                        excluded.toArray(new ComponentName[0]));
                startActivity(chooser);
            }
        } catch (RuntimeException e) {
            // The other app went away or refuses: nothing to fall back on.
        }
    }
}
