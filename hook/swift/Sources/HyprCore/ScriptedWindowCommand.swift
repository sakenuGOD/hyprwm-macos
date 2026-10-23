import Foundation

/// A public, installed scripting definition, never an application-name focus rule.
public struct ScriptedWindowCommand:Equatable {
    public let eventClass:UInt32,eventID:UInt32
    public init?(_ definition:String) {
        guard definition.utf8.count<=524288,
              let document=try? XMLDocument(xmlString:definition,options:.nodeLoadExternalEntitiesNever),
              let commands=try? document.nodes(forXPath:"//suite/command[@name='new window']"),commands.count==1,
              let command=commands.first as? XMLElement,let code=command.attribute(forName:"code")?.stringValue,
              code.utf8.count==8,code.utf8.allSatisfy({$0>=32 && $0<127}) else{return nil}
        let bytes=Array(code.utf8)
        eventClass=bytes.prefix(4).reduce(UInt32(0)){($0<<8)|UInt32($1)}
        eventID=bytes.suffix(4).reduce(UInt32(0)){($0<<8)|UInt32($1)}
    }
}
