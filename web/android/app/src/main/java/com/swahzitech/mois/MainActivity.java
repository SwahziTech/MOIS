package com.swahzitech.mois;

import android.os.Bundle;

import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        // MOIS's own plugins (registered before the bridge starts)
        registerPlugin(PrinterPlugin.class);
        super.onCreate(savedInstanceState);
    }
}
