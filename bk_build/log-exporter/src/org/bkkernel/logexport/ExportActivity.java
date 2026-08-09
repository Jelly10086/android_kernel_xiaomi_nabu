package org.bkkernel.logexport;

import android.app.Activity;
import android.content.ActivityNotFoundException;
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
    private String name;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        if (state != null) {
            name = state.getString("name");
            source = sourceFor(name);
            return;
        }

        name = getIntent().getStringExtra("name");
        source = sourceFor(name);
        if (!validSource(source)) {
            Toast.makeText(this, "日志导出文件无效", Toast.LENGTH_SHORT).show();
            finish();
            return;
        }

        Intent save = new Intent(Intent.ACTION_CREATE_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType("application/gzip")
                .putExtra(Intent.EXTRA_TITLE, name)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION
                        | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        try {
            startActivityForResult(save, CREATE_LOG);
        } catch (ActivityNotFoundException | SecurityException error) {
            Toast.makeText(this, "无法打开文件管理器", Toast.LENGTH_SHORT).show();
            source.delete();
            finish();
        }
    }

    @Override
    protected void onSaveInstanceState(Bundle state) {
        super.onSaveInstanceState(state);
        if (name != null) state.putString("name", name);
    }

    private File sourceFor(String fileName) {
        if (fileName == null || !fileName.matches("bkk-control-[0-9-]+\\.tar\\.gz")) {
            return null;
        }
        return new File(getFilesDir(), fileName);
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
        } catch (IOException | SecurityException ignored) {
            Toast.makeText(this, "日志保存失败", Toast.LENGTH_SHORT).show();
            return false;
        }
    }
}
