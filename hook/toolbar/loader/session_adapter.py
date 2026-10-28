"""Source-only palette integration seam; no factory/default autoload installed."""
class NativeMenuAdapter:
 def __init__(self,manager,durable_state,prepare_handoffs=None):
  self.manager=manager;self.durable_state=durable_state;self.prepare_handoffs=prepare_handoffs;self.handoffs_ready=False
 def ensure_handoffs(self):
  """Global pre-load barrier, called only under the coordinator apply lock."""
  if self.handoffs_ready:return
  if not callable(self.prepare_handoffs):raise ValueError('explicit reviewed legacy ownership inventory required before new loads')
  for envelope in self.prepare_handoffs():
   owner=envelope['payload'];i=owner['identity']
   # A replaced/dead generation cannot retain its original injected image.
   # Read-only kernel identity only; never attach a recycled PID for cleanup.
   current=self.manager.runtime.identity(i['pid'])
   if current is None:
    import os
    try:os.kill(i['pid'],0)
    except ProcessLookupError:continue
    except PermissionError:raise ValueError('legacy birth is unreadable, not proven gone')
    raise ValueError('legacy process exists but exact identity is unavailable')
   if current!=i:continue
   self.manager.adopt_existing(envelope)
  self.handoffs_ready=True
 def matches(self,identity,application):
  return not self.manager.bundles.excluded(application) and identity.get('pid')==application.get('pid') and identity.get('birth')==application.get('birth')
 def handle(self,event,context,identity,application,palette):
  del palette
  if context.get('apply_lock_held') is not True or context.get('colorsctl_reentry_allowed') is not False or any(context.get(k) is not False for k in ('allow_restart','allow_input','allow_true_focus','allow_core_reset')):
   return {'state':'pending','attempted':False,'reason':'exact existing coordinator effect boundary required'}
  if context.get('epoch')!=self.manager.grant['epoch']:return {'state':'skipped','attempted':False,'reason':'different menu grant epoch'}
  if event=='off':
   durable=self.durable_state()
   if durable.get('enabled') is True and durable.get('wallpaper_epoch')==context['epoch']:return {'state':'skipped','attempted':False,'reason':'observer restart preserves same enabled menu epoch'}
   pending=self.manager.disable();return {'state':'pending' if pending else 'off','attempted':True,'pending':pending}
  if event not in ('startup','application_launched','application_activated'):return {'state':'skipped','attempted':False,'reason':'not a native app-menu load event'}
  if identity is None or application is None:return {'state':'pending','attempted':False,'reason':'waiting for native per-application event; no process scan'}
  if not self.manager.enabled:return {'state':'off','attempted':False,'reason':'durable native menu kill-switch'}
  try:self.ensure_handoffs()
  except (ValueError,OSError,KeyError,TypeError) as error:return {'state':'pending','attempted':False,'reason':'legacy ownership barrier: '+str(error)}
  value=self.manager.application(event,application)
  return {**value,'attempted':value.get('attempted',False)}
 def terminated(self,context,application):
  """Exact native cached event cleanup only: never resolves/attaches dead PID."""
  if context.get('apply_lock_held') is not True or context.get('epoch')!=self.manager.grant['epoch'] or context.get('colorsctl_reentry_allowed') is not False or any(context.get(k) is not False for k in ('allow_restart','allow_input','allow_true_focus','allow_core_reset')):
   return {'state':'skipped','attempted':False,'reason':'termination cleanup requires exact cached-epoch context'}
  return self.manager.handle({'event':'application_terminated','application':application})
