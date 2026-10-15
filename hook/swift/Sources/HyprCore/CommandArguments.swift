import Foundation

/// Parses native hotkey JSON argv and quoted text, without shell expansion.
public enum CommandArguments {
    public static func parse(_ line: String) throws -> [String] {
        guard line.utf8.count <= 65536, !line.contains("\0") else { throw CmdError("command: invalid size or NUL") }
        let text=line.trimmingCharacters(in:.whitespacesAndNewlines)
        if text.hasPrefix("[") {
            guard let array=try JSON.parse(text).array, array.count <= 128 else { throw CmdError("command: expected bounded argv array") }
            return try array.map { value in
                guard let argument=value.string, argument.utf8.count <= 8192, !argument.contains("\0") else { throw CmdError("command: expected string argument") }
                return argument
            }
        }
        var output:[String]=[], current="", quote:Character?, escaped=false, begun=false
        for character in text {
            if escaped { current.append(character);escaped=false;begun=true;continue }
            if character == "\\", quote != "'" { escaped=true;begun=true;continue }
            if let active=quote {
                if character == active { quote=nil } else { current.append(character) };continue
            }
            if character == "'" || character == "\"" { quote=character;begun=true }
            else if character.isWhitespace {
                if begun { output.append(current);current="";begun=false }
            } else { current.append(character);begun=true }
        }
        guard quote == nil, !escaped else { throw CmdError("command: unterminated quote or escape") }
        if begun { output.append(current) }
        guard output.count <= 128, output.allSatisfy({ $0.utf8.count <= 8192 }) else { throw CmdError("command: arguments exceed limit") }
        return output
    }
    static func windowID(_ value: String) throws -> Int {
        guard let wid=UInt32(value), wid > 0 else { throw CmdError("command: window ID must be 1..4294967295") }
        return Int(wid)
    }
}
