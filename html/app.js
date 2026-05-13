/* global GetParentResourceName */

const resourceName = () =>
  typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'dizzy-phone';

function post(callback, data) {
  return fetch(`https://${resourceName()}/${callback}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=UTF-8' },
    body: JSON.stringify(data || {}),
  }).then(async (r) => {
    const t = await r.text();
    if (!t) return null;
    try {
      return JSON.parse(t);
    } catch {
      return t;
    }
  });
}

/** Synthetic contact row for “Me” — not stored server-side */
const CONTACT_SELF_ID = '__dizzy_self__';

const state = {
  boot: null,
  contacts: [],
  messages: [],
  notes: [],
  threadWith: null,
  editingContact: null,
  editingNote: null,
  dial: '',
  outboundDial: '',
  incoming: null,
  socialAppId: null,
  photos: [],
  viewingPhotoId: null,
  serviceJob: null,
  serviceLabel: null,
  cellCamActive: false,
};

function $(sel) {
  return document.querySelector(sel);
}

function formatMoney(n) {
  const x = Number(n) || 0;
  return '$' + x.toLocaleString('en-US');
}

function esc(s) {
  const d = document.createElement('div');
  d.textContent = s;
  return d.innerHTML;
}

function showScreen(id) {
  document.querySelectorAll('main.screen').forEach((el) => el.classList.remove('active'));
  const t = document.getElementById(id);
  if (t) t.classList.add('active');
  document.querySelectorAll('.dock-btn').forEach((btn) => {
    btn.classList.toggle('active', btn.getAttribute('data-go') === id);
  });
  if (id === 'screen-appstore') renderAppStore();
  if (id === 'screen-airdrop') refreshAirDropList();
  if (id === 'screen-social' && state.socialAppId) showSocialApp();
  if (id === 'screen-gallery') refreshPhotos();
  if (id === 'screen-camera') applyCameraHint();
  if (id === 'screen-services') refreshServices();
  if (id === 'screen-service-staff') refreshServiceStaff();
  if (id === 'screen-mygarage') refreshMyGarage();
}

function hideAirdropModal() {
  const m = $('#airdrop-modal');
  if (m) m.classList.add('hidden');
}

function showAirdropModal(d) {
  if (!d) return;
  const n = $('#ad-name');
  const p = $('#ad-phone');
  if (n) n.textContent = d.fromName || 'Unknown';
  if (p) p.textContent = d.fromPhone || '';
  const m = $('#airdrop-modal');
  if (m) m.classList.remove('hidden');
}

function renderAppStore() {
  const box = $('#store-list');
  if (!box || !state.boot) return;
  const installed = new Set(state.boot.installedApps || []);
  const catalog = state.boot.appCatalog || [];
  box.innerHTML = '';
  catalog.forEach((app) => {
    const row = document.createElement('div');
    row.className = 'store-card';
    const ico = document.createElement('div');
    ico.className = 'store-ico';
    ico.textContent = app.icon || '📱';
    const meta = document.createElement('div');
    meta.className = 'store-meta';
    const strong = document.createElement('strong');
    strong.textContent = app.name || app.id;
    const desc = document.createElement('span');
    desc.className = 'meta';
    desc.textContent = app.description || '';
    const badge = document.createElement('span');
    badge.className = 'badge';
    badge.textContent = app.category || 'App';
    meta.appendChild(strong);
    meta.appendChild(desc);
    meta.appendChild(badge);
    const actions = document.createElement('div');
    actions.className = 'store-actions';
    const btn = document.createElement('button');
    btn.type = 'button';
    const has = installed.has(app.id);
    btn.className = has ? 'btn danger sm' : 'btn primary sm';
    btn.textContent = has ? 'Remove' : 'Get';
    btn.addEventListener('click', async () => {
      const res = has
        ? await post('uninstallApp', { appId: app.id })
        : await post('installApp', { appId: app.id });
      if (res && res.ok && res.installedApps) {
        state.boot.installedApps = res.installedApps;
        buildAppGrid();
        renderAppStore();
      }
    });
    actions.appendChild(btn);
    row.appendChild(ico);
    row.appendChild(meta);
    row.appendChild(actions);
    box.appendChild(row);
  });
}

async function refreshAirDropList() {
  const ul = $('#airdrop-nearby');
  if (!ul) return;
  const rows = await post('getAirDropNearby');
  ul.innerHTML = '';
  const list = Array.isArray(rows) ? rows : [];
  if (!list.length) {
    const li = document.createElement('li');
    li.className = 'hint';
    li.textContent = 'No players in range. Tap Scan nearby.';
    ul.appendChild(li);
    return;
  }
  list.forEach((r) => {
    const li = document.createElement('li');
    const left = document.createElement('div');
    const strong = document.createElement('strong');
    strong.textContent = r.name || 'Citizen';
    const meta = document.createElement('div');
    meta.className = 'meta';
    meta.textContent = `${r.dist != null ? r.dist : '?'}m`;
    left.appendChild(strong);
    left.appendChild(meta);
    const send = document.createElement('button');
    send.type = 'button';
    send.className = 'btn primary sm';
    send.textContent = 'Send';
    send.addEventListener('click', () => post('airdropSend', { targetServerId: r.serverId }));
    li.appendChild(left);
    li.appendChild(send);
    ul.appendChild(li);
  });
}

function showSocialApp() {
  if (!state.boot) return;
  const catalog = state.boot.appCatalog || [];
  const app = catalog.find((x) => x.id === state.socialAppId);
  const t = $('#social-title');
  if (t) t.textContent = app ? app.name : 'Social';
  refreshSocialPosts();
}

async function refreshSocialPosts() {
  if (!state.socialAppId) return;
  const rows = await post('getSocialPosts', { appId: state.socialAppId });
  const box = $('#social-feed');
  if (!box) return;
  box.innerHTML = '';
  const list = Array.isArray(rows) ? rows : [];
  if (!list.length) {
    const empty = document.createElement('p');
    empty.className = 'hint';
    empty.textContent = 'No posts yet. Say something.';
    box.appendChild(empty);
    return;
  }
  list.forEach((p) => {
    const div = document.createElement('div');
    div.className = 'social-post';
    div.innerHTML = `
      <div class="who">${esc(p.author_name || 'Citizen')}</div>
      <div class="mono">${esc(p.author_phone || '')}</div>
      <div class="body">${esc(p.body || '')}</div>
      <span class="ts">${esc(p.created_at || '')}</span>`;
    box.appendChild(div);
  });
}

function applyCameraHint() {
  const hint = $('#camera-hint');
  if (!hint || !state.boot) return;
  const cam = state.boot.camera || {};
  if (cam.available === false) {
    hint.textContent =
      'Camera needs the screenshot resource running (usually screenshot-basic). In server.cfg start it before dizzy-phone, then reopen the phone.';
    return;
  }
  if (cam.useCellCamera) {
    hint.textContent =
      'Tap Capture for the in-game camera (LB-style HUD: grid, ring shutter, flip). Aim with the mouse, scroll to zoom, then tap the white ring to save to Gallery. Escape closes.';
    return;
  }
  if (!cam.uploadConfigured) {
    hint.textContent =
      'Tap Capture to hide the phone briefly, snap what you see in-game, and save the photo to Gallery (stored in your server database).';
  } else {
    const r = cam.resource || 'screenshot-basic';
    hint.textContent =
      'Capture uploads the shot via your configured host, then saves the link in Gallery (' + r + ').';
  }
}

async function refreshPhotos() {
  const rows = await post('getPhotos');
  state.photos = Array.isArray(rows) ? rows : [];
  renderGallery();
}

function renderGallery() {
  const grid = $('#gallery-grid');
  if (!grid) return;
  grid.innerHTML = '';
  if (!state.photos.length) {
    const p = document.createElement('p');
    p.className = 'hint';
    p.style.gridColumn = '1 / -1';
    p.textContent = 'No photos yet. Use the camera or paste a link above.';
    grid.appendChild(p);
    return;
  }
  state.photos.forEach((ph) => {
    const cell = document.createElement('div');
    cell.className = 'gallery-thumb';
    const img = document.createElement('img');
    img.src = ph.image_url;
    img.alt = '';
    img.loading = 'lazy';
    img.referrerPolicy = 'no-referrer';
    img.addEventListener('error', () => {
      img.remove();
      const fallback = document.createElement('div');
      fallback.className = 'ph';
      fallback.textContent = 'No preview';
      cell.appendChild(fallback);
    });
    cell.appendChild(img);
    cell.addEventListener('click', () => openPhotoViewer(ph));
    grid.appendChild(cell);
  });
}

function openPhotoViewer(p) {
  state.viewingPhotoId = p.id;
  const overlay = $('#photo-viewer');
  const im = $('#pv-img');
  const cap = $('#pv-caption');
  const dt = $('#pv-date');
  if (im) {
    im.src = p.image_url;
    im.alt = p.caption || 'Photo';
  }
  if (cap) cap.textContent = p.caption || '';
  if (dt) dt.textContent = p.created_at || '';
  if (overlay) overlay.classList.remove('hidden');
}

function closePhotoViewer() {
  state.viewingPhotoId = null;
  const overlay = $('#photo-viewer');
  if (overlay) overlay.classList.add('hidden');
}

function setCallSpeakerButtonHidden(hidden) {
  const b = $('#call-speaker');
  if (!b) return;
  b.classList.toggle('hidden', hidden);
}

function setCallSpeakerButtonActive(on) {
  const b = $('#call-speaker');
  if (!b) return;
  b.classList.toggle('active', !!on);
  b.setAttribute('aria-pressed', on ? 'true' : 'false');
}

function startOutboundCall(phone) {
  const n = (phone || '').trim();
  if (!n || !state.boot) return;
  state.dial = n;
  const disp = $('#dial-display');
  if (disp) disp.textContent = n;
  if (state.boot.enableCalls) {
    post('callStart', { phone: n });
  } else {
    setCallSpeakerButtonHidden(true);
    setCallSpeakerButtonActive(false);
    $('#call-overlay').classList.remove('hidden');
    $('#call-status').textContent = 'Unavailable';
    $('#call-peer').textContent = 'Voice calls are disabled';
    setTimeout(hideOverlays, 2200);
  }
}

async function refreshServices() {
  const ul = $('#services-list');
  if (!ul) return;
  const rows = await post('getServices');
  const list = Array.isArray(rows) ? rows : [];
  ul.innerHTML = '';
  if (!list.length) {
    const li = document.createElement('li');
    li.className = 'hint';
    li.textContent = 'No businesses configured. Edit Config.ServiceDirectory in dizzy-phone.';
    ul.appendChild(li);
    return;
  }
  list.forEach((s) => {
    const li = document.createElement('li');
    const left = document.createElement('div');
    const strong = document.createElement('strong');
    strong.textContent = s.label || s.job;
    const meta = document.createElement('div');
    meta.className = 'meta';
    meta.textContent = s.open
      ? `${s.onDuty} on duty — tap to call staff`
      : 'Closed — no one clocked on';
    left.appendChild(strong);
    left.appendChild(meta);
    const pill = document.createElement('span');
    pill.className = 'status-pill ' + (s.open ? 'open' : 'closed');
    pill.textContent = s.open ? 'Open' : 'Closed';
    li.appendChild(left);
    li.appendChild(pill);
    li.style.cursor = 'pointer';
    li.addEventListener('click', () => {
      state.serviceJob = s.job;
      state.serviceLabel = s.label || s.job;
      const t = $('#service-staff-title');
      if (t) t.textContent = state.serviceLabel;
      showScreen('screen-service-staff');
    });
    ul.appendChild(li);
  });
}

function myGarageErrText(err) {
  const map = {
    disabled: 'Garage app is disabled.',
    garage: 'Garage system is not running. Start qb-garages.',
    phone: 'You need a phone.',
    plate: 'Invalid vehicle.',
    notfound: 'Vehicle not found.',
    notgaraged: 'That vehicle is not stored in a garage.',
    depot: 'Pay the depot fee at impound first.',
    funds: 'Not enough cash for the delivery fee.',
    config: 'Garage setup error. Check Config.PhoneGarageFallback.',
    unknown: 'Something went wrong.',
  };
  return map[err] || map.unknown;
}

async function refreshMyGarage() {
  const ul = $('#mygarage-list');
  const st = $('#mygarage-status');
  const feeEl = $('#mygarage-fee');
  if (!ul || !state.boot) return;
  if (st) st.textContent = '';
  const fee = Number(state.boot.phoneGarageValetFee) || 0;
  if (feeEl) feeEl.textContent = fee > 0 ? `Delivery fee: $${fee} cash` : 'No delivery fee';
  const rows = await post('getGarageVehiclesPhone');
  const list = Array.isArray(rows) ? rows : [];
  ul.innerHTML = '';
  if (!list.length) {
    const li = document.createElement('li');
    li.className = 'hint';
    li.textContent =
      'No vehicles in garage. Only cars with state “parked” (not out, not impound, no depot fee) appear here.';
    ul.appendChild(li);
    return;
  }
  list.forEach((v) => {
    const li = document.createElement('li');
    const left = document.createElement('div');
    const strong = document.createElement('strong');
    strong.textContent = v.label || v.vehicle;
    const meta = document.createElement('div');
    meta.className = 'meta';
    meta.textContent = `${v.plate || ''} · ${v.garageLabel || 'Garage'}`;
    left.appendChild(strong);
    left.appendChild(meta);
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'btn primary sm';
    btn.textContent = 'Get vehicle';
    btn.addEventListener('click', async () => {
      if (st) st.textContent = '';
      const res = await post('deliverGarageVehicle', { plate: v.plate });
      if (res && res.ok) {
        if (st) st.textContent = 'Requested — check the garage lot.';
        await refreshMyGarage();
      } else if (st) {
        st.textContent = myGarageErrText(res && res.err);
      }
    });
    li.appendChild(left);
    li.appendChild(btn);
    ul.appendChild(li);
  });
}

async function refreshServiceStaff() {
  const ul = $('#service-staff-list');
  const hint = $('#service-staff-hint');
  if (!ul || !state.serviceJob) return;
  if (hint) hint.textContent = 'Loading on-duty staff…';
  const rows = await post('getServiceStaff', { job: state.serviceJob });
  const list = Array.isArray(rows) ? rows : [];
  ul.innerHTML = '';
  if (hint) {
    hint.textContent =
      list.length > 0
        ? 'Tap Call to ring an on-duty worker (voice calls must be enabled).'
        : 'No on-duty staff with a phone number right now.';
  }
  list.forEach((w) => {
    const li = document.createElement('li');
    const left = document.createElement('div');
    const strong = document.createElement('strong');
    strong.textContent = w.name || 'Staff';
    const meta = document.createElement('div');
    meta.className = 'meta mono';
    meta.textContent = w.phone + (w.grade ? ` · ${w.grade}` : '');
    left.appendChild(strong);
    left.appendChild(meta);
    const call = document.createElement('button');
    call.type = 'button';
    call.className = 'btn primary sm';
    call.textContent = 'Call';
    call.addEventListener('click', (e) => {
      e.stopPropagation();
      startOutboundCall(w.phone);
    });
    li.appendChild(left);
    li.appendChild(call);
    ul.appendChild(li);
  });
}

function tickClock() {
  const d = new Date();
  const h = d.getHours().toString().padStart(2, '0');
  const m = d.getMinutes().toString().padStart(2, '0');
  const el = $('#clock');
  if (el) el.textContent = `${h}:${m}`;
}

function contactNameFor(num) {
  if (state.boot && state.boot.myPhone && String(state.boot.myPhone) === String(num)) {
    return 'Me';
  }
  const row = state.contacts.find((c) => c.phone_number === num);
  return row ? row.contact_name : num;
}

function contactSelfMatchesSearch(q, myPhone) {
  if (!myPhone) return false;
  const raw = (q || '').trim().toLowerCase();
  if (!raw) return true;
  const phoneDigits = String(myPhone).replace(/\D/g, '');
  const qDigits = raw.replace(/\D/g, '');
  if (qDigits.length >= 2 && phoneDigits.includes(qDigits)) return true;
  const aliases = ['me', 'my', 'self', 'mine', 'my number', 'this phone'];
  if (aliases.includes(raw)) return true;
  return aliases.some((a) => a.length >= raw.length && a.startsWith(raw));
}

function buildAppGrid() {
  const grid = $('#app-grid');
  if (!grid || !state.boot) return;
  const base = [
    { id: 'screen-dialer', ico: '☎', label: 'Phone' },
    { id: 'screen-messages', ico: '✉', label: 'Messages' },
    { id: 'screen-contacts', ico: '👤', label: 'Contacts' },
    { id: 'screen-services', ico: '🏢', label: 'Services' },
    { id: 'screen-wallet', ico: '💳', label: 'Wallet' },
    { id: 'screen-notes', ico: '📝', label: 'Notes' },
    { id: 'screen-maps', ico: '📍', label: 'Maps' },
    { id: 'screen-camera', ico: '📷', label: 'Camera' },
    { id: 'screen-gallery', ico: '🖼', label: 'Gallery' },
  ];
  if (state.boot.phoneGarage) {
    base.push({ id: 'screen-mygarage', ico: '🚗', label: 'My Garage' });
  }
  base.push(
    { id: 'screen-appstore', ico: '🛒', label: 'Store' },
    { id: 'screen-airdrop', ico: '📡', label: 'AirDrop' },
    { id: 'screen-settings', ico: '⚙', label: 'Settings' }
  );
  const installed = new Set(state.boot.installedApps || []);
  const catalog = state.boot.appCatalog || [];
  const apps = [...base];
  catalog.forEach((app) => {
    if (installed.has(app.id)) {
      apps.push({
        id: 'screen-social',
        ico: app.icon || '💬',
        label: app.name,
        socialAppId: app.id,
      });
    }
  });
  grid.innerHTML = '';
  apps.forEach((a) => {
    const t = document.createElement('div');
    t.className = 'app-tile';
    t.innerHTML = `<span class="ico">${a.ico}</span><span>${esc(a.label)}</span>`;
    t.addEventListener('click', () => {
      if (a.socialAppId) {
        state.socialAppId = a.socialAppId;
        showSocialApp();
        showScreen('screen-social');
      } else {
        showScreen(a.id);
      }
    });
    grid.appendChild(t);
  });
}

function openSendMoneyForPhone(phone) {
  const num = (phone || '').trim();
  if (!num || !state.boot || !state.boot.enableTransfer) return;
  const trPhone = $('#tr-phone');
  const trAmt = $('#tr-amount');
  if (trPhone) trPhone.value = num;
  if (trAmt) trAmt.value = '';
  showScreen('screen-wallet');
  setTimeout(() => {
    if (trAmt) trAmt.focus();
  }, 80);
}

function renderContacts() {
  const ul = $('#contact-list');
  if (!ul) return;
  const q = ($('#contact-search').value || '').toLowerCase();
  ul.innerHTML = '';
  const my = state.boot && state.boot.myPhone;
  const fromBook = state.contacts.filter(
    (c) =>
      !q ||
      (c.contact_name && c.contact_name.toLowerCase().includes(q)) ||
      (c.phone_number && c.phone_number.includes(q))
  );
  const rows = [];
  if (my && contactSelfMatchesSearch(q, my)) {
    rows.push({
      id: CONTACT_SELF_ID,
      contact_name: 'Me',
      phone_number: my,
      favorite: 0,
      _isSelf: true,
    });
  }
  fromBook.forEach((c) => rows.push(c));

  rows.forEach((c) => {
    const isSelf = c._isSelf === true || c.id === CONTACT_SELF_ID;
    const li = document.createElement('li');
    li.className = isSelf ? 'contact-self' : 'contact-row';

    const main = document.createElement('div');
    main.className = 'contact-main';
    main.innerHTML = `
      <strong>${esc(c.contact_name)}${c.favorite ? ' <span class="fav-star">★</span>' : ''}</strong>
      <div class="meta mono">${esc(c.phone_number)}</div>
      ${isSelf ? '<div class="meta contact-self-hint">Your number</div>' : ''}`;
    main.addEventListener('click', () => {
      state.dial = c.phone_number;
      showScreen('screen-dialer');
      $('#dial-display').textContent = state.dial;
    });
    main.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      if (isSelf) return;
      openContactEditor(c);
    });

    li.appendChild(main);

    if (!isSelf) {
      const quick = document.createElement('div');
      quick.className = 'contact-quick';

      const callBtn = document.createElement('button');
      callBtn.type = 'button';
      callBtn.className = 'btn primary sm';
      callBtn.textContent = 'Call';
      callBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        startOutboundCall(c.phone_number);
      });

      const msgBtn = document.createElement('button');
      msgBtn.type = 'button';
      msgBtn.className = 'btn ghost sm';
      msgBtn.textContent = 'Text';
      msgBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        openThread(c.phone_number);
      });

      quick.appendChild(callBtn);
      quick.appendChild(msgBtn);

      if (state.boot && state.boot.enableTransfer) {
        const payBtn = document.createElement('button');
        payBtn.type = 'button';
        payBtn.className = 'btn secondary sm';
        payBtn.textContent = 'Pay';
        payBtn.title = 'Send bank transfer';
        payBtn.addEventListener('click', (e) => {
          e.stopPropagation();
          openSendMoneyForPhone(c.phone_number);
        });
        quick.appendChild(payBtn);
      }

      li.appendChild(quick);
    }

    ul.appendChild(li);
  });
}

function openContactEditor(c) {
  if (c && (c._isSelf || c.id === CONTACT_SELF_ID)) return;
  const panel = $('#contact-editor');
  state.editingContact = c ? c.id : null;
  $('#editor-title').textContent = c ? 'Edit contact' : 'New contact';
  $('#editor-name').value = c ? c.contact_name : '';
  $('#editor-phone').value = c ? c.phone_number : '';
  $('#editor-fav').checked = c ? !!c.favorite : false;
  panel.classList.remove('hidden');
}

function closeContactEditor() {
  $('#contact-editor').classList.add('hidden');
  state.editingContact = null;
}

async function refreshContacts() {
  const rows = await post('getContacts');
  state.contacts = Array.isArray(rows) ? rows : [];
  renderContacts();
}

function threadKey(a, b) {
  return a < b ? `${a}|${b}` : `${b}|${a}`;
}

function buildThreads() {
  const my = state.boot.myPhone;
  const map = new Map();
  state.messages.forEach((m) => {
    const other = m.from_phone === my ? m.to_phone : m.from_phone;
    const k = threadKey(my, other);
    const prev = map.get(k);
    if (!prev || new Date(m.created_at) > new Date(prev.created_at)) {
      map.set(k, { other, last: m });
    }
  });
  return Array.from(map.values()).sort(
    (x, y) => new Date(y.last.created_at) - new Date(x.last.created_at)
  );
}

function renderThreads() {
  const ul = $('#thread-list');
  if (!ul) return;
  ul.innerHTML = '';
  buildThreads().forEach((t) => {
    const li = document.createElement('li');
    const unread =
      t.last.to_phone === state.boot.myPhone &&
      t.last.from_phone === t.other &&
      !t.last.is_read;
    li.innerHTML = `
      <div>
        <strong>${esc(contactNameFor(t.other))}</strong>
        <div class="meta">${esc(t.last.body.slice(0, 42))}${t.last.body.length > 42 ? '…' : ''}</div>
      </div>
      <span class="meta">${unread ? '●' : ''}</span>`;
    li.addEventListener('click', () => openThread(t.other));
    ul.appendChild(li);
  });
}

function parseGps(body) {
  const m = String(body).match(/^GPS:\s*([-\d.]+)\s*,\s*([-\d.]+)/i);
  if (!m) return null;
  return { x: parseFloat(m[1]), y: parseFloat(m[2]) };
}

function renderChat() {
  const box = $('#chat-messages');
  if (!box || !state.threadWith || !state.boot) return;
  const my = state.boot.myPhone;
  const other = state.threadWith;
  $('#thread-title').textContent = contactNameFor(other);
  box.innerHTML = '';
  const rows = state.messages
    .filter(
      (m) =>
        (m.from_phone === my && m.to_phone === other) || (m.from_phone === other && m.to_phone === my)
    )
    .sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
  rows.forEach((m) => {
    const div = document.createElement('div');
    const me = m.from_phone === my;
    div.className = 'bubble ' + (me ? 'me' : 'them');
    const gps = parseGps(m.body);
    let inner = esc(m.body);
    if (gps) {
      inner = `📍 Shared location<br><a class="gps" data-x="${gps.x}" data-y="${gps.y}">Set waypoint</a>`;
    }
    div.innerHTML = `${inner}<span class="ts">${esc(m.created_at || '')}</span>`;
    const a = div.querySelector('a.gps');
    if (a) {
      a.addEventListener('click', (e) => {
        e.preventDefault();
        post('setWaypoint', { x: gps.x, y: gps.y });
      });
    }
    box.appendChild(div);
  });
  box.scrollTop = box.scrollHeight;
}

function openThread(other) {
  state.threadWith = other;
  post('markRead', { other });
  showScreen('screen-thread');
  renderChat();
}

async function refreshMessages() {
  const rows = await post('getMessages');
  state.messages = Array.isArray(rows) ? rows : [];
  renderThreads();
  if (state.threadWith) renderChat();
}

function renderNotes() {
  const ul = $('#note-list');
  if (!ul) return;
  ul.innerHTML = '';
  state.notes.forEach((n) => {
    const li = document.createElement('li');
    li.innerHTML = `<div><strong>${esc(n.title)}</strong><div class="meta">${esc(
      (n.body || '').slice(0, 40)
    )}${(n.body || '').length > 40 ? '…' : ''}</div></div><span class="meta">›</span>`;
    li.addEventListener('click', () => openNoteEditor(n));
    ul.appendChild(li);
  });
}

function openNoteEditor(n) {
  state.editingNote = n ? n.id : null;
  $('#note-editor').classList.remove('hidden');
  $('#note-title').value = n ? n.title : '';
  $('#note-body').value = n ? n.body || '' : '';
  $('#note-del').classList.toggle('hidden', !n);
}

function closeNoteEditor() {
  $('#note-editor').classList.add('hidden');
  state.editingNote = null;
}

async function refreshNotes() {
  const rows = await post('getNotes');
  state.notes = Array.isArray(rows) ? rows : [];
  renderNotes();
}

function applyBoot() {
  const b = state.boot;
  $('#home-name').textContent = (b.name || 'Citizen').trim() || 'Citizen';
  $('#w-cash').textContent = formatMoney(b.cash);
  $('#w-bank').textContent = formatMoney(b.bank);
  $('#set-my-number').textContent = 'This device: ' + b.myPhone;
  const tr = $('#transfer-box');
  if (tr) tr.classList.toggle('hidden', !b.enableTransfer);
  buildAppGrid();
  applyCameraHint();
}

function buildDialPad() {
  const pad = $('#dial-pad');
  if (!pad) return;
  pad.innerHTML = '';
  const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'];
  keys.forEach((k) => {
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = k;
    b.addEventListener('click', () => {
      state.dial += k;
      $('#dial-display').textContent = state.dial;
    });
    pad.appendChild(b);
  });
}

function hideOverlays() {
  $('#call-overlay').classList.add('hidden');
  $('#incoming-overlay').classList.add('hidden');
}

window.addEventListener('message', (e) => {
  const msg = e.data;
  if (!msg || !msg.action) return;
  if (msg.action === 'open') {
    state.boot = msg.data;
    state.cellCamActive = false;
    document.body.classList.remove('cell-camera-active');
    const cellOv = $('#camera-cell-overlay');
    if (cellOv) cellOv.classList.add('hidden');
    const cellGrid = $('#camera-cell-grid');
    if (cellGrid) cellGrid.classList.add('hidden');
    $('#root').classList.remove('hidden');
    showScreen('screen-home');
    applyBoot();
    buildDialPad();
    state.dial = '';
    $('#dial-display').textContent = '';
    hideOverlays();
    refreshContacts();
    refreshMessages();
    refreshNotes();
    refreshPhotos();
  }
  if (msg.action === 'close') {
    $('#root').classList.add('hidden');
    if (!msg.preserveCallUi) {
      hideOverlays();
    }
    hideAirdropModal();
    closePhotoViewer();
    const cBtn = $('#camera-shutter');
    const cSt = $('#camera-status');
    if (cBtn) cBtn.disabled = false;
    if (cSt) cSt.textContent = '';
  }
  if (msg.action === 'airdropIncoming') {
    showAirdropModal(msg.data);
  }
  if (msg.action === 'galleryRefresh') {
    refreshPhotos();
  }
  if (msg.action === 'photoSavedToGallery') {
    refreshPhotos();
    showScreen('screen-gallery');
  }
  if (msg.action === 'cameraStatus') {
    const st = $('#camera-status');
    const btn = $('#camera-shutter');
    if (st) st.textContent = msg.text || '';
    if (btn) btn.disabled = !!msg.busy;
  }
  if (msg.action === 'cameraCellMode') {
    state.cellCamActive = !!msg.active;
    document.body.classList.toggle('cell-camera-active', !!msg.active);
    const ov = $('#camera-cell-overlay');
    if (ov) ov.classList.toggle('hidden', !msg.active);
    const grid = $('#camera-cell-grid');
    if (grid) {
      const show = !!msg.active && msg.showGrid !== false;
      grid.classList.toggle('hidden', !show);
    }
    const flip = $('#cell-cam-flip');
    if (flip) {
      if (!msg.active) flip.classList.add('hidden');
      else flip.classList.toggle('hidden', !msg.allowFlip);
    }
  }
  if (msg.action === 'money' && state.boot) {
    state.boot.cash = msg.cash;
    state.boot.bank = msg.bank;
    $('#w-cash').textContent = formatMoney(msg.cash);
    $('#w-bank').textContent = formatMoney(msg.bank);
  }
  if (msg.action === 'messagePush' && msg.row) {
    state.messages.unshift(msg.row);
    renderThreads();
    if (state.threadWith) renderChat();
  }
  if (msg.action === 'incomingCall') {
    state.incoming = msg.data;
    $('#in-name').textContent = msg.data.fromName || msg.data.fromPhone;
    $('#in-phone').textContent = msg.data.fromPhone || '';
    $('#incoming-overlay').classList.remove('hidden');
  }
  if (msg.action === 'callResult') {
    if (msg.reason === 'ringing') {
      setCallSpeakerButtonHidden(true);
      setCallSpeakerButtonActive(false);
      state.outboundDial = msg.dial || '';
      $('#call-overlay').classList.remove('hidden');
      $('#call-status').textContent = 'Ringing…';
      const peer =
        contactNameFor(state.outboundDial) || state.outboundDial || state.dial || '—';
      $('#call-peer').textContent = peer;
    } else if (msg.reason === 'unavailable') {
      state.outboundDial = '';
      setCallSpeakerButtonHidden(true);
      setCallSpeakerButtonActive(false);
      $('#call-status').textContent = 'No signal';
      $('#call-peer').textContent = 'Subscriber unavailable';
      setTimeout(hideOverlays, 2000);
    } else if (msg.reason === 'busy') {
      state.outboundDial = '';
      setCallSpeakerButtonHidden(true);
      setCallSpeakerButtonActive(false);
      $('#call-status').textContent = 'Busy';
      setTimeout(hideOverlays, 2000);
    }
  }
  if (msg.action === 'callConnected') {
    state.outboundDial = '';
    $('#call-overlay').classList.remove('hidden');
    $('#call-status').textContent = 'In call';
    $('#call-peer').textContent = contactNameFor(msg.data.withPhone) || msg.data.withPhone;
    setCallSpeakerButtonHidden(false);
    setCallSpeakerButtonActive(false);
  }
  if (msg.action === 'callSpeaker') {
    setCallSpeakerButtonActive(!!msg.on);
  }
  if (msg.action === 'callEnded') {
    setCallSpeakerButtonHidden(true);
    setCallSpeakerButtonActive(false);
    hideOverlays();
    state.incoming = null;
    state.outboundDial = '';
  }
});

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    if (state.cellCamActive) {
      post('cellCameraCancel');
      return;
    }
    const pv = $('#photo-viewer');
    if (pv && !pv.classList.contains('hidden')) {
      closePhotoViewer();
      return;
    }
    const m = $('#airdrop-modal');
    if (m && !m.classList.contains('hidden')) {
      post('airdropDecline');
      hideAirdropModal();
      return;
    }
    post('close');
  }
});

document.querySelectorAll('.dock-btn').forEach((b) => {
  b.addEventListener('click', () => showScreen(b.getAttribute('data-go')));
});

$('#dial-clear').addEventListener('click', () => {
  state.dial = '';
  $('#dial-display').textContent = '';
});

$('#dial-call').addEventListener('click', () => {
  startOutboundCall(state.dial.trim());
});

$('#contact-search').addEventListener('input', renderContacts);
$('#contact-add-btn').addEventListener('click', () => openContactEditor(null));
$('#editor-cancel').addEventListener('click', closeContactEditor);
$('#editor-save').addEventListener('click', async () => {
  if (state.editingContact === CONTACT_SELF_ID) return;
  await post('contactSave', {
    contact_name: $('#editor-name').value,
    phone_number: $('#editor-phone').value.trim(),
    favorite: $('#editor-fav').checked,
  });
  closeContactEditor();
  refreshContacts();
});

$('#thread-back').addEventListener('click', () => showScreen('screen-messages'));

$('#chat-send').addEventListener('click', async () => {
  const body = $('#chat-input').value.trim();
  if (!body || !state.threadWith) return;
  await post('sendMessage', { to: state.threadWith, body });
  $('#chat-input').value = '';
  await refreshMessages();
});

const chatGpsBtn = document.getElementById('chat-gps');
if (chatGpsBtn) {
  chatGpsBtn.addEventListener('click', async () => {
    if (!state.threadWith) return;
    const c = await post('getMyCoords');
    if (!c || c.x == null) return;
    const body = `GPS:${c.x},${c.y}`;
    await post('sendMessage', { to: state.threadWith, body });
    await refreshMessages();
  });
}

$('#chat-input').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') $('#chat-send').click();
});

$('#tr-send').addEventListener('click', async () => {
  const phone = $('#tr-phone').value.trim();
  const amount = $('#tr-amount').value;
  const res = await post('bankTransfer', { phone, amount: Number(amount) });
  if (res.ok) {
    state.boot.cash = res.cash;
    state.boot.bank = res.bank;
    $('#w-cash').textContent = formatMoney(res.cash);
    $('#w-bank').textContent = formatMoney(res.bank);
    $('#tr-phone').value = '';
    $('#tr-amount').value = '';
  }
});

$('#maps-here').addEventListener('click', async () => {
  const c = await post('getMyCoords');
  if (c && c.x != null) post('setWaypoint', { x: c.x, y: c.y });
});

$('#maps-go').addEventListener('click', () => {
  const x = parseFloat($('#maps-x').value);
  const y = parseFloat($('#maps-y').value);
  if (!isNaN(x) && !isNaN(y)) post('setWaypoint', { x, y });
});

$('#note-new').addEventListener('click', () => openNoteEditor(null));
$('#note-save').addEventListener('click', async () => {
  await post('noteSave', {
    id: state.editingNote,
    title: $('#note-title').value,
    body: $('#note-body').value,
  });
  closeNoteEditor();
  refreshNotes();
});
$('#note-del').addEventListener('click', async () => {
  if (!state.editingNote) return;
  await post('noteDelete', { id: state.editingNote });
  closeNoteEditor();
  refreshNotes();
});

const callSpeakerBtn = $('#call-speaker');
if (callSpeakerBtn) {
  callSpeakerBtn.addEventListener('click', () => post('callToggleSpeaker'));
}
$('#call-hangup').addEventListener('click', () => post('callHangup'));
$('#in-accept').addEventListener('click', () => {
  post('callAccept');
  $('#incoming-overlay').classList.add('hidden');
});
$('#in-decline').addEventListener('click', () => {
  post('callDecline');
  $('#incoming-overlay').classList.add('hidden');
});

const airdropRefresh = $('#airdrop-refresh');
if (airdropRefresh) airdropRefresh.addEventListener('click', () => refreshAirDropList());

const socialBack = $('#social-back');
if (socialBack) socialBack.addEventListener('click', () => showScreen('screen-home'));

const socialPostBtn = $('#social-post');
if (socialPostBtn) {
  socialPostBtn.addEventListener('click', async () => {
    const ta = $('#social-input');
    const body = ((ta && ta.value) || '').trim();
    if (!body || !state.socialAppId) return;
    await post('createSocialPost', { appId: state.socialAppId, body });
    if (ta) ta.value = '';
    await refreshSocialPosts();
  });
}

const adDecline = $('#ad-decline');
if (adDecline) {
  adDecline.addEventListener('click', () => {
    post('airdropDecline');
    hideAirdropModal();
  });
}
const adSave = $('#ad-save');
if (adSave) {
  adSave.addEventListener('click', async () => {
    await post('airdropAccept');
    hideAirdropModal();
    await refreshContacts();
  });
}

const cellCamCancel = $('#cell-cam-cancel');
if (cellCamCancel) cellCamCancel.addEventListener('click', () => post('cellCameraCancel'));
const cellCamFlip = $('#cell-cam-flip');
if (cellCamFlip) cellCamFlip.addEventListener('click', () => post('cellCameraFlip'));
const cellCamShutter = $('#cell-cam-shutter');
if (cellCamShutter) cellCamShutter.addEventListener('click', () => post('cellCameraShutter'));

const camBtn = $('#camera-shutter');
if (camBtn) {
  camBtn.addEventListener('click', () => {
    const capEl = $('#camera-caption');
    const cap = (capEl && capEl.value.trim()) || '';
    post('takePhoto', { caption: cap });
  });
}

const galAdd = $('#gallery-url-add');
if (galAdd) {
  galAdd.addEventListener('click', async () => {
    const uEl = $('#gallery-url-input');
    const cEl = $('#gallery-url-caption');
    const url = (uEl && uEl.value.trim()) || '';
    const cap = (cEl && cEl.value.trim()) || '';
    if (!url) return;
    const saved = await post('savePhotoUrl', { url, caption: cap });
    if (saved && saved.ok) {
      if (uEl) uEl.value = '';
      if (cEl) cEl.value = '';
      await refreshPhotos();
    }
  });
}

const pvClose = $('#pv-close');
if (pvClose) pvClose.addEventListener('click', () => closePhotoViewer());

const pvDel = $('#pv-delete');
if (pvDel) {
  pvDel.addEventListener('click', async () => {
    if (!state.viewingPhotoId) return;
    await post('deletePhoto', { id: state.viewingPhotoId });
    closePhotoViewer();
    await refreshPhotos();
  });
}

const servicesRefresh = $('#services-refresh');
if (servicesRefresh) servicesRefresh.addEventListener('click', () => refreshServices());

const serviceStaffBack = $('#service-staff-back');
if (serviceStaffBack) {
  serviceStaffBack.addEventListener('click', () => showScreen('screen-services'));
}

const myGarageRefresh = $('#mygarage-refresh');
if (myGarageRefresh) myGarageRefresh.addEventListener('click', () => refreshMyGarage());

$('#set-dark').addEventListener('change', (e) => {
  document.body.classList.toggle('light', !e.target.checked);
});
$('#set-scale').addEventListener('input', (e) => {
  const s = Number(e.target.value) / 100;
  document.querySelector('.phone-shell').style.transform = `scale(${s})`;
});

setInterval(tickClock, 1000);
tickClock();
post('ready');
