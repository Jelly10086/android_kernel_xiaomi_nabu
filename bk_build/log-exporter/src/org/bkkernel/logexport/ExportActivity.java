package org.bkkernel.logexport;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.widget.Toast;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

public final class ExportActivity extends Activity {
    private static final int CREATE_LOG = 1;
    private File source;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        if (state != null) {
            String path = state.getString("source");
            source = path == null ? null : new File(path);
            return;
        }

        String path = getIntent().getStringExtra("source");
        String name = getIntent().getStringExtra("name");
        source = path == null ? null : new File(path);
        if (!validSource(source) || name == null || !name.matches("bkk-control-[0-9-]+\\.tar\\.gz")) {
            finish();
            return;
        }

        Intent save = new Intent(Intent.ACTION_CREATE_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType("application/gzip")
                .putExtra(Intent.EXTRA_TITLE, name);
        startActivityForResult(save, CREATE_LOG);
    }

    @Override
    protected void onSaveInstanceState(Bundle state) {
        super.onSaveInstanceState(state);
        if (source != null) state.putString("source", source.getPath());
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != CREATE_LOG) return;

        boolean saved = false;
        if (resultCode == RESULT_OK && data != null && data.getData() != null && validSource(source)) {
            saved = copyTo(source, data.getData());
        }
        if (source != null) source.delete();
        if (saved) Toast.makeText(this, "日志已保存", Toast.LENGTH_SHORT).show();
        finish();
    }

    private boolean validSource(File file) {
        File files = getFilesDir();
        if (file == null || files == null || !file.isFile()) return false;
        try {
            String root = files.getCanonicalPath() + File.separator;
            return file.getCanonicalPath().startsWith(root);
        } catch (IOException ignored) {
            return false;
        }
    }

    private boolean copyTo(File from, Uri to) {
        try (InputStream input = new FileInputStream(from);
             OutputStream output = getContentResolver().openOutputStream(to, "w")) {
            if (output == null) return false;
            byte[] buffer = new byte[64 * 1024];
            int count;
            while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
            output.flush();
            return true;
        } catch (IOException ignored) {
            Toast.makeText(this, "日志保存失败", Toast.LENGTH_SHORT).show();
            return false;
        }
    }
}
