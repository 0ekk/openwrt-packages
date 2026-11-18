'use strict';
'require view';
'require form';
'require fs';
'require poll';
'require dom';

// Which inbound flow lists are expanded, kept across the 5 s status refresh.
const flowsOpen = { udp: false, tcp: false };

function getStatus() {
	return fs.exec_direct('/usr/share/fullcone/fullcone.sh', [ 'status' ], 'json').catch(() => null);
}

// Conntrack prints IPv6 uncompressed; shorten it as RFC 5952 does (longest run of 2+ zero groups).
function ip6short(a) {
	const g = a.split(':').map(x => x.replace(/^0+(?=.)/, ''));
	let best = -1, len = 1;

	for (let i = 0; i < g.length; i++) {
		let j = i;
		while (j < g.length && g[j] === '0')
			j++;
		if (j - i > len) {
			best = i;
			len = j - i;
		}
		i = j;
	}

	return best < 0 ? g.join(':') : g.slice(0, best).join(':') + '::' + g.slice(best + len).join(':');
}

function hostPort(ip, port) {
	return ip.indexOf(':') < 0 ? ip + ':' + port : '[' + ip6short(ip) + ']:' + port;
}

function renderFlows(st, proto) {
	const n = st['inbound_' + proto] ?? 0;
	const flows = (st.flows || []).filter(f => f.proto === proto);

	if (!flows.length)
		return String(n);

	const attrs = { toggle: ev => flowsOpen[proto] = ev.target.open };
	if (flowsOpen[proto])
		attrs.open = '';

	return E('details', attrs, [
		E('summary', { 'style': 'cursor:pointer' }, String(n)),
		E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Remote')),
				E('th', { 'class': 'th' }, _('WAN port')),
				E('th', { 'class': 'th' }, _('LAN host')),
				E('th', { 'class': 'th' }, _('Expires in'))
			]),
			...flows.map(f => E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, hostPort(f.remote, f.rport)),
				E('td', { 'class': 'td' }, String(f.port)),
				E('td', { 'class': 'td' }, hostPort(f.lan, f.lport)),
				E('td', { 'class': 'td' }, '%ds'.format(f.timeout))
			]))
		]),
		n > flows.length ? E('em', {}, _('First %d shown').format(flows.length)) : ''
	]);
}

function renderStatus(st) {
	if (!st)
		return E('em', {}, _('Status unavailable'));

	const modes = {
		fullcone: st.tcp ? _('Active: LAN UDP and TCP use full cone NAT') : _('Active: LAN UDP uses full cone NAT'),
		fallback: _('Enabled, but the rules failed to load: plain masquerade (see the system log)'),
		disabled: _('Disabled: plain masquerade'),
		broken: _('Inconsistent state: reload the firewall')
	};
	const ipv6 = {
		off: _('Off'),
		active: _('Active for %s').format(st.lan6 || '-'),
		inactive: _('Set, but inactive: no firewall zone masquerades IPv6 (masq6), or no IPv6 LAN subnet (see the system log)')
	};
	const rows = [
		[ _('Mode'), (modes[st.mode] || st.mode) + (st.forced ? ' ' + _('(forced, not saved in the config)') : '') ],
		[ _('IPv6 (NAT66)'), ipv6[st.ipv6] || ipv6.off ],
		[ _('Kernel module'), st.module_loaded ? _('loaded') : _('not loaded') ],
		[ _('LAN subnet'), st.lan || '-' ],
		[ _('WAN device'), st.wan || '-' ],
		[ _('Inbound UDP flows to the LAN'), renderFlows(st, 'udp') ],
		[ _('Inbound TCP flows to the LAN'), renderFlows(st, 'tcp') ]
	];

	return E('table', { 'class': 'table' }, rows.map(r => E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '33%' }, r[0]),
		E('td', { 'class': 'td left' }, r[1])
	])));
}

return view.extend({
	load() {
		return getStatus();
	},

	render(st) {
		const m = new form.Map('fullcone', _('Full Cone NAT'),
			_('Endpoint-independent mapping and filtering (NAT1) for UDP from the LAN, optionally TCP and masqueraded IPv6.'));
		const s = m.section(form.NamedSection, 'main', 'fullcone', _('Settings'));
		let o;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;

		o = s.option(form.Flag, 'tcp', _('TCP'),
			_('Also full cone for TCP: anyone on the internet can open a TCP connection to a port a LAN host has connected from, while that connection lasts. Off: TCP keeps the normal masquerade.'));
		o.rmempty = false;

		o = s.option(form.Flag, 'ipv6', _('IPv6 (NAT66)'),
			_('Also full cone for IPv6 that the router masquerades (masq6 on the wan zone, e.g. a LAN with only ULA addresses). Has no effect without masq6: IPv6 with public LAN addresses is not NATed.'));
		o.rmempty = false;

		o = s.option(form.Value, 'lan_subnet', _('LAN subnet'),
			_('IPv4 subnet that gets full cone NAT. Empty: derived from the lan interface.'));
		o.datatype = 'cidr4';
		o.placeholder = st?.lan || '';

		o = s.option(form.Value, 'lan6_subnet', _('LAN IPv6 subnet'),
			_('IPv6 subnet that gets full cone NAT66. Empty: the ULA prefix.'));
		o.datatype = 'cidr6';
		o.placeholder = st?.lan6 || '';
		o.depends('ipv6', '1');

		o = s.option(form.Value, 'wan_device', _('WAN device'),
			_('Egress device. Empty: derived from the wan interface (pppoe-wan for PPPoE).'));
		o.placeholder = st?.wan || '';

		o = s.option(form.DynamicList, 'exclude_port', _('Excluded inbound ports'),
			_('Inbound UDP (and TCP, if enabled) to these ports is never forwarded to the LAN, so router services keep them.'));
		o.datatype = 'port';

		return m.render().then(node => {
			const box = E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Status')),
				E('div', { 'id': 'fullcone-status' }, renderStatus(st))
			]);

			node.insertBefore(box, node.querySelector('.cbi-section'));
			poll.add(() => getStatus().then(st =>
				dom.content(document.getElementById('fullcone-status'), renderStatus(st))), 5);

			return node;
		});
	}
});
