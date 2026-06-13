/**
 * Lamp controller — Gmail relay.
 * Bound to v.lamp.controller@gmail.com. A 1-minute time trigger runs pollLamp(),
 * which forwards unread "subject:lamp" mail to the Worker's /ingest endpoint and
 * acts on the verdict (mark read; reply on failure). All Gmail mutations live here;
 * the Worker is pure decision logic.
 *
 * Setup: Project Settings → Script Properties:
 *   WORKER_URL    e.g. https://lamp-controller.<subdomain>.workers.dev
 *   RELAY_SECRET  must equal the Worker's RELAY_SHARED_SECRET
 * Then add a time-driven trigger for pollLamp, every 1 minute.
 */

var BATCH = 10;

function pollLamp() {
  var props = PropertiesService.getScriptProperties();
  var workerUrl = props.getProperty('WORKER_URL');
  var relaySecret = props.getProperty('RELAY_SECRET');
  if (!workerUrl || !relaySecret) {
    throw new Error('Set WORKER_URL and RELAY_SECRET in Script Properties.');
  }

  var threads = GmailApp.search('is:unread subject:lamp', 0, BATCH);
  for (var i = 0; i < threads.length; i++) {
    var messages = threads[i].getMessages();
    var msg = messages[messages.length - 1]; // latest message in the thread
    handleMessage(msg, workerUrl, relaySecret);
  }
}

function handleMessage(msg, workerUrl, relaySecret) {
  var payload = {
    msgId: msg.getId(),
    from: msg.getFrom(),
    subject: msg.getSubject(),
    body: msg.getPlainBody(),
  };

  var response;
  try {
    response = UrlFetchApp.fetch(workerUrl + '/ingest', {
      method: 'post',
      contentType: 'application/json',
      headers: { Authorization: 'Bearer ' + relaySecret },
      payload: JSON.stringify(payload),
      muteHttpExceptions: true,
    });
  } catch (e) {
    Logger.log('relay: POST failed for %s: %s (leaving unread)', payload.msgId, e);
    return; // transport failure — leave unread, retry next tick
  }

  var code = response.getResponseCode();
  if (code !== 200) {
    // 5xx (transient), 401 (misconfigured secret), 400 (bad payload) — all left
    // unread so nothing is silently dropped; fix config / retry next tick.
    Logger.log('relay: worker %s for %s (leaving unread)', code, payload.msgId);
    return;
  }

  var verdict = JSON.parse(response.getContentText());
  if (verdict.reply) {
    msg.reply(verdict.reply);
  }
  msg.markRead();
  Logger.log('relay: %s -> %s', payload.msgId, verdict.status);
}
