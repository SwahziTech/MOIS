import { useState } from 'react';
import { Copy, Check, Phone, Smartphone } from 'lucide-react';

/*
 * Where the money goes, ready to pay (2026-11-16, the user: copy + open the app; one-tap payment through
 * Snippe comes in the last phase). The director picks how they pay; each detail has a Copy button; for
 * CRDB, NMB and mobile money a button opens the USSD menu on the phone. Then they pay in their bank or
 * money app, come back and post the SMS or the screenshot as proof.
 *   payTo: { bank, no, name }  amount: number  reference: text
 */
const MODES = [
  ['crdb', 'CRDB'],
  ['bank', 'Other bank'],
  ['mobile', 'Mobile money'],
];
// USSD menus (dialled from a phone): the bank's or the network's own menu, where the person pays
const USSD = { crdb: '*150*03#', nmb: '*150*66#', mpesa: '*150*00#', mixx: '*150*01#', airtel: '*150*60#', halopesa: '*150*88#' };
// the bank's or network's own app on an Android phone (2026-11-16, the user: "bring the NMB app").
// Play Store ids from public app listings (not confirmed with the banks): when one is wrong or the app is
// not installed, the phone goes to the Play Store search for the app instead.
const APPS = {
  crdb: { pkg: 'apps.crdbbank.com.mobapp', name: 'CRDB SimBanking' },
  nmb: { pkg: 'com.nmb10.eclectics', name: 'NMB Mkononi' },
  mpesa: { pkg: 'com.vodafone.mpesa.tanzania', name: 'M-Pesa' },
  mixx: { pkg: 'tz.tigo.mfsapp', name: 'Mixx by Yas' },
  airtel: { pkg: null, name: 'Airtel Money' },
  halopesa: { pkg: null, name: 'HaloPesa' },
};
const isAndroid = () => typeof navigator !== 'undefined' && /Android/i.test(navigator.userAgent);
// launch the app's start screen (MAIN + LAUNCHER — with only the package, Android finds nothing to open and
// falls back, 2026-11-16: NMB Mkononi installed but the Play Store opened); if it can't, the app's own Play
// Store page, which shows "Open" when it is installed
const appLink = a => {
  if (!a.pkg) return `https://play.google.com/store/search?q=${encodeURIComponent(a.name)}&c=apps`;
  const store = `https://play.google.com/store/apps/details?id=${a.pkg}`;
  return `intent:#Intent;action=android.intent.action.MAIN;category=android.intent.category.LAUNCHER;package=${a.pkg};S.browser_fallback_url=${encodeURIComponent(store)};end`;
};
const NETWORKS = [['mpesa', 'M-Pesa'], ['mixx', 'Mixx by Yas'], ['airtel', 'Airtel Money'], ['halopesa', 'HaloPesa']];
// banks in Tanzania other than CRDB, for the drop-down (2026-11-16, the user); "Another bank" lets one be typed
const BANKS = ['NMB', 'NBC', 'Selcom Microfinance Bank', 'Exim Bank', 'Stanbic Bank', 'Absa Bank', 'Equity Bank', 'Azania Bank',
  'DTB (Diamond Trust Bank)', 'TCB (Tanzania Commercial Bank)', 'KCB Bank', 'I&M Bank', 'Access Bank', 'Akiba Commercial Bank',
  'Amana Bank', 'Mkombozi Commercial Bank', 'Mwalimu Commercial Bank', 'Bank of Africa', 'Ecobank', 'Standard Chartered',
  'Citibank', 'Letshego Bank', 'Maendeleo Bank', 'DCB Commercial Bank', 'Uchumi Commercial Bank', 'Yetu Microfinance Bank',
  'Mwanga Hakika Bank', 'China Dasheng Bank', 'Bank of Baroda', 'Bank of India', 'Habib African Bank', 'UBA'];
const bankOf = name => BANKS.find(b => b.toLowerCase().split(/[ (]/)[0] === String(name ?? '').toLowerCase().trim().split(/[ (]/)[0]) ?? '';

const guessMode = bank => {
  const b = String(bank ?? '').toLowerCase();
  if (/crdb/.test(b)) return 'crdb';
  if (/m-?pesa|vodacom|tigo|mixx|yas|airtel|halo/.test(b)) return 'mobile';
  return b ? 'bank' : 'crdb';
};
const guessNet = bank => {
  const b = String(bank ?? '').toLowerCase();
  return /tigo|mixx|yas/.test(b) ? 'mixx' : /airtel/.test(b) ? 'airtel' : /halo/.test(b) ? 'halopesa' : 'mpesa';
};

// a Tanzanian mobile number: 0[67]xxxxxxxx, 255[67]xxxxxxxx or +255… (spaces allowed)
const phoneOk = v => /^(0|255|\+255)[67]\d{8}$/.test(String(v ?? '').replace(/[\s-]/g, ''));
const isPhoneLike = v => phoneOk(v);

// the details can be changed here before paying (2026-11-16, the user); onReference: the reference posted with the payment
export default function PayTo({ payTo, amount, reference, money, onReference }) {
  const [mode, setMode] = useState(() => guessMode(payTo?.bank));
  const [net, setNet] = useState(() => guessNet(payTo?.bank));
  const [bank, setBank] = useState(() => bankOf(payTo?.bank) || (payTo?.bank && !/crdb/i.test(payTo.bank) ? '__other' : 'NMB'));
  const [otherBank, setOtherBank] = useState(() => (bankOf(payTo?.bank) ? '' : payTo?.bank && !/crdb/i.test(payTo.bank) ? payTo.bank : ''));
  const bankName = bank === '__other' ? otherBank : bank;
  const [acct, setAcct] = useState(() => (isPhoneLike(payTo?.no) ? '' : payTo?.no ?? ''));
  const [phone, setPhone] = useState(() => (isPhoneLike(payTo?.no) ? payTo.no : ''));
  const [name, setName] = useState(payTo?.name ?? '');
  const [ref, setRef] = useState(reference ?? '');
  const setReference = v => { setRef(v); onReference?.(v); };
  const no = mode === 'mobile' ? phone : acct;
  const badPhone = mode === 'mobile' && phone.trim() && !phoneOk(phone);
  const [copied, setCopied] = useState('');
  async function copy(key, text) {
    try { await navigator.clipboard.writeText(String(text ?? '')); }
    catch {
      const t = document.createElement('textarea'); t.value = String(text ?? ''); document.body.appendChild(t); t.select();
      try { document.execCommand('copy'); } catch { /* the person can still read it */ }
      t.remove();
    }
    setCopied(key); setTimeout(() => setCopied(c => (c === key ? '' : c)), 1500);
  }
  const amt = Math.round(Number(amount) || 0);
  // [label, value, copy?, shown, onEdit, placeholder]
  const rows = [
    [mode === 'mobile' ? 'Network' : 'Bank', mode === 'mobile' ? NETWORKS.find(n => n[0] === net)?.[1] : mode === 'crdb' ? 'CRDB' : bankName, false],
    mode === 'mobile'
      ? ['Phone number', phone, true, null, setPhone, 'e.g. 0712 345 678']
      : ['Account number', acct, true, null, setAcct, 'Account number'],
    ['Name', name, true, null, setName, 'Name on the account'],
    ['Amount', amt ? String(amt) : '', true, amt ? money(amt) : ''],
    ['Reference', ref, true, null, setReference, 'Reference'],
  ];
  const ussd = mode === 'crdb' ? USSD.crdb : mode === 'mobile' ? USSD[net] : bank === 'NMB' ? USSD.nmb : null;
  const app = mode === 'crdb' ? APPS.crdb : mode === 'mobile' ? APPS[net] : bank === 'NMB' ? APPS.nmb : null;
  const all = rows.filter(r => r[1]).map(r => `${r[0]}: ${r[3] || r[1]}`).join('\n');
  return (
    <div className="payto">
      <div className="pe-field"><span>Pay by</span>
        <div className="filter-chips" role="radiogroup" aria-label="Pay by">
          {MODES.map(([k, l]) => <button key={k} type="button" role="radio" aria-checked={mode === k} className={`filter-chip${mode === k ? ' is-on' : ''}`} onClick={() => setMode(k)}>{l}</button>)}
        </div>
      </div>
      {mode === 'mobile' && (
        <label className="pe-field"><span>Network</span>
          <select className="form-input" value={net} onChange={e => setNet(e.target.value)}>
            {NETWORKS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}
          </select></label>
      )}
      {mode === 'bank' && (
        <div className="form-row">
          <label className="pe-field"><span>Bank</span>
            <select className="form-input" value={bank} onChange={e => setBank(e.target.value)}>
              {BANKS.map(b => <option key={b} value={b}>{b}</option>)}
              <option value="__other">Another bank…</option>
            </select></label>
          {bank === '__other' && <label className="pe-field"><span>Bank name</span><input className="form-input" value={otherBank} onChange={e => setOtherBank(e.target.value)} /></label>}
        </div>
      )}
      <div className="payto-card">
        {rows.map(([label, value, canCopy, shown, onEdit, placeholder]) => (
          <div key={label} className="payto-row">
            <span className="pl-help">{label}</span>
            {onEdit && (label === 'Name' || label === 'Reference')
              // long words wrap onto a second line instead of being cut (phones)
              ? <textarea className="payto-input payto-wrap" rows={1} value={value ?? ''} placeholder={placeholder} aria-label={label} onChange={e => onEdit(e.target.value.replace(/\n/g, ' '))} />
              : onEdit
              ? <input className={`payto-input${label === 'Phone number' && badPhone ? ' is-bad' : ''}`} value={value ?? ''} placeholder={placeholder} aria-label={label}
                  inputMode={label === 'Phone number' || label === 'Account number' ? 'numeric' : undefined} onChange={e => onEdit(e.target.value)} />
              : <strong className="payto-val">{shown || value || '—'}</strong>}
            {canCopy && value ? (
              <button type="button" className="btn btn-ghost btn-sm" aria-label={`Copy ${label.toLowerCase()}`} title={`Copy ${label.toLowerCase()}`} onClick={() => copy(label, value)}>
                {copied === label ? <Check size={14} /> : <Copy size={14} />}</button>
            ) : <span />}
          </div>
        ))}
      </div>
      {mode === 'mobile' && (!phone.trim() || badPhone) && <p className="text-sm text-warning" style={{ margin: 0 }}>{phone.trim() ? 'That is not a valid phone number — e.g. 0712 345 678 or 255712345678.' : 'Enter the phone number to send to.'}</p>}
      <div className="payto-actions">
        <button type="button" className="btn btn-outline btn-sm" onClick={() => copy('all', all)}>{copied === 'all' ? <Check size={14} /> : <Copy size={14} />} Copy all</button>
        {app && isAndroid() && <a className="btn btn-primary btn-sm" href={appLink(app)} title={`Open the ${app.name} app on this phone`}><Smartphone size={14} /> Open {app.name} app</a>}
        {ussd && <a className={`btn ${app && isAndroid() ? 'btn-outline' : 'btn-primary'} btn-sm`} href={`tel:${ussd.replace(/#/g, '%23')}`} title={`Dial ${ussd} on this phone`}><Phone size={14} /> Dial {ussd}</a>}
      </div>
      <p className="pl-help" style={{ margin: 0 }} title="Copy each detail, pay in your bank or money app (or the menu above), then come back and post the SMS or a screenshot below.">
        Pay in your {mode === 'mobile' ? 'money' : 'bank'} app, then post the SMS or screenshot below.</p>
    </div>
  );
}
