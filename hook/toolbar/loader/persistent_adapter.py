"""Bind the signed menu policy independently of wallpaper epochs."""
from session_adapter import NativeMenuAdapter


class PersistentMenuAdapter(NativeMenuAdapter):
    def handle(self,event,context,identity,application,palette):
        durable=self.durable_state()
        if event=='off' and durable.get('enabled') is True:
            return {'state':'skipped','attempted':False,'reason':'enabled independent menu policy survives observer/wallpaper changes'}
        if event!='off' and (durable.get('enabled') is not True or durable.get('wallpaper_epoch')!=context.get('epoch')):
            return {'state':'skipped','attempted':False,'reason':'current committed theme context required'}
        policy_context={**context,'epoch':self.manager.grant['epoch']}
        return super().handle(event,policy_context,identity,application,palette)
    def terminated(self,context,application):
        return super().terminated({**context,'epoch':self.manager.grant['epoch']},application)
