const $ = (id) => document.getElementById(id);
chrome.storage.local.get(['host', 'port', 'token']).then((c) => {
  if (c.host) $('host').value = c.host;
  if (c.port) $('port').value = c.port;
  if (c.token) $('token').value = c.token;
});
$('save').onclick = async () => {
  await chrome.storage.local.set({
    host: $('host').value.trim(),
    port: parseInt($('port').value, 10) || 0,
    token: $('token').value.trim(),
  });
  $('status').textContent = ' Saved';
};
