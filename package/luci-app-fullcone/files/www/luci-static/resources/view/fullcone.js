'use strict';
'require view';
'require form';
'require fs';
'require poll';
'require dom';

function getStatus() {
	return fs.exec_direct('/usr/share/fullcone/fullcone.sh', [ 'status' ], 'json').catch(() => null);
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
	const rows = [
		[ _('Mode'), (modes[st.mode] || st.mode) + (st.forced ? ' ' + _('(forced, not saved in the config)') : '') ],
		[ _('Kernel module'), st.module_loaded ? _('loaded') : _('not loaded') ],
		[ _('LAN subnet'), st.lan || '-' ],
		[ _('WAN device'), st.wan || '-' ],
		[ _('Inbound UDP flows to the LAN'), String(st.inbound_udp) ],
		[ _('Inbound TCP flows to the LAN'), String(st.inbound_tcp ?? 0) ]
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
			_('Endpoint-independent mapping and filtering (NAT1) for IPv4 UDP from the LAN, and optionally TCP.'));
		const s = m.section(form.NamedSection, 'main', 'fullcone', _('Settings'));
		let o;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;

		o = s.option(form.Flag, 'tcp', _('TCP'),
			_('Also full cone for TCP: anyone on the internet can open a TCP connection to a port a LAN host has connected from, while that connection lasts. Off: TCP keeps the normal masquerade.'));
		o.rmempty = false;

		o = s.option(form.Value, 'lan_subnet', _('LAN subnet'),
			_('IPv4 subnet that gets full cone NAT. Empty: derived from the lan interface.'));
		o.datatype = 'cidr4';
		o.placeholder = st?.lan || '';

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
