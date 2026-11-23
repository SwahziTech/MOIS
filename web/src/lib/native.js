import { Capacitor, registerPlugin } from '@capacitor/core';

/*
 * The phone app (2026-11-23): MOIS's Android app is this web app inside Capacitor (web/android).
 * A few things a browser does that the app's web view can't, done the phone's way here:
 *   files  — no download bar: Excel, CSV, PDFs and pictures go to the phone's share sheet
 *            (WhatsApp, Drive, Files…)
 *   apps   — "intent:" links (open the bank's app) aren't followed: the app is opened by its package,
 *            else its Play Store page
 *   print  — window.print() does nothing: Android's print service (print or Save as PDF) instead,
 *            through the small Printer plugin in MainActivity.java
 * In a browser every helper does what the page did before.
 */
export const isApp = () => Capacitor.isNativePlatform();

const Printer = registerPlugin('Printer');

/** Print the page: the browser's print, or Android's print service in the app */
export async function printPage(title = document.title) {
  if (!isApp()) { window.print(); return; }
  try { await Printer.print({ name: title || 'MOIS' }); } catch (e) { console.error(e); window.alert("Couldn't open printing on this phone."); }
}

const toBase64 = blob => new Promise((ok, fail) => {
  const r = new FileReader();
  r.onload = () => ok(String(r.result).split(',')[1] ?? '');
  r.onerror = () => fail(r.error);
  r.readAsDataURL(blob);
});

/**
 * A file the page made (Excel, CSV, PDF, picture): downloaded in a browser; in the app it is saved
 * on the phone and the share sheet opens with it. → 'shared' | 'downloaded'
 */
export async function saveFile(blob, fileName, text) {
  if (isApp()) {
    const [{ Filesystem, Directory }, { Share }] = await Promise.all([import('@capacitor/filesystem'), import('@capacitor/share')]);
    const safe = String(fileName || 'MOIS').replace(/[\\/:*?"<>|]+/g, '-');
    const { uri } = await Filesystem.writeFile({ path: safe, data: await toBase64(blob), directory: Directory.Cache });
    try { await Share.share({ title: safe, text: text || undefined, files: [uri] }); } catch (e) { if (!/cancel/i.test(String(e?.message))) throw e; }
    return 'shared';
  }
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob); a.download = fileName;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 5000);
  return 'downloaded';
}

/** Open another app on the phone by its Android package, else its Play Store page. true when handled. */
export async function openAndroidApp(pkg) {
  if (!isApp() || !pkg) return false;
  const { AppLauncher } = await import('@capacitor/app-launcher');
  try {
    const { value } = await AppLauncher.canOpenUrl({ url: pkg });
    if (value) { await AppLauncher.openUrl({ url: pkg }); return true; }
  } catch { /* not installed, or not visible: the store page */ }
  await AppLauncher.openUrl({ url: `https://play.google.com/store/apps/details?id=${pkg}` });
  return true;
}
