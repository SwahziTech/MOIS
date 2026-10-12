#!/usr/bin/env node
/**
 * Directly set a user's password with the service-role key
 * (supabase.auth.admin.updateUserById) — no reset email.
 *
 *   node scripts/set-user-password.js <email>
 *
 * The password is typed at a hidden prompt: it is never echoed, logged,
 * written to disk or passed on the command line (so it stays out of shell
 * history). Run it in your own terminal.
 */
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env'), quiet: true });
const { createClient } = require('@supabase/supabase-js');

const email = (process.argv[2] || '').trim().toLowerCase();
if (!email) {
  console.error('Usage: node scripts/set-user-password.js <email>');
  process.exit(1);
}
const { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY } = process.env;
if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set in .env');
  process.exit(1);
}

function promptHidden(label) {
  return new Promise((resolve, reject) => {
    const { stdin, stdout } = process;
    if (!stdin.isTTY) return reject(new Error('Run this in an interactive terminal.'));
    stdout.write(label);
    stdin.setRawMode(true);
    stdin.resume();
    stdin.setEncoding('utf8');
    let value = '';
    const onData = ch => {
      if (ch === '\u0003') { stdout.write('\n'); process.exit(130); }      // Ctrl+C
      if (ch === '\r' || ch === '\n') {
        stdin.setRawMode(false); stdin.pause(); stdin.off('data', onData);
        stdout.write('\n');
        return resolve(value);
      }
      if (ch === '\u007f' || ch === '\b') { value = value.slice(0, -1); return; } // Backspace
      value += ch;
    };
    stdin.on('data', onData);
  });
}

(async () => {
  const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });

  let userId;
  for (let page = 1; !userId; page++) {
    const { data, error } = await sb.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) throw error;
    userId = data.users.find(u => (u.email || '').toLowerCase() === email)?.id;
    if (data.users.length < 1000) break;
  }
  if (!userId) throw new Error(`No user with email ${email}`);

  const pw1 = await promptHidden(`New password for ${email}: `);
  const pw2 = await promptHidden('Repeat new password: ');
  if (pw1 !== pw2) throw new Error('Passwords do not match — nothing changed.');
  if (pw1.length < 12) throw new Error('Use at least 12 characters — nothing changed.');

  const { error } = await sb.auth.admin.updateUserById(userId, { password: pw1 });
  if (error) throw error;
  console.log(`Password updated for ${email}. Existing sessions stay signed in until they expire.`);
})().catch(e => { console.error('Failed:', e.message); process.exit(1); });
