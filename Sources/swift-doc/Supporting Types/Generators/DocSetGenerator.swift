import Foundation
import HypertextLiteral
import SwiftDoc
import class SwiftDoc.Module
import SwiftSemantics
import struct SwiftSemantics.Protocol
import SQLite

fileprivate typealias XML = HTML

enum DocSetGenerator: Generator {
    static func generate(for module: Module, with options: SwiftDoc.Generate.Options) throws {
        assert(options.format == .docset)

        let outputDirectoryURL = URL(fileURLWithPath: options.output)
        try fileManager.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true, attributes: fileAttributes)

        let docsetURL = outputDirectoryURL.appendingPathComponent("\(module.name).docset")

        let docsetDocumentsDirectoryURL = docsetURL.appendingPathComponent("Contents/Resources/Documents/")
        try fileManager.createDirectory(at: docsetDocumentsDirectoryURL, withIntermediateDirectories: true, attributes: fileAttributes)

        var options = options
        options.format = .html
        options.output = docsetDocumentsDirectoryURL.path
        try HTMLGenerator.generate(for: module, with: options)

        let info: [String: Any] = [
            "CFBundleIdentifier": module.name.lowercased(),
            "CFBundleName": module.name,
            "DocSetPlatformFamily": "swift",
            "isDashDocset": true,
            "DashDocSetFamily": "dashtoc",
            "dashIndexFilePath": "index.html"
        ]

        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: docsetURL.appendingPathComponent("Contents/Info.plist"))

        let indexURL = docsetURL.appendingPathComponent("Contents/Resources/docSet.dsidx")

        let db = try Connection(indexURL.path)

        let searchIndex = Table("searchIndex")

        let id = Expression<Int64>("id")
        let name = Expression<String?>("name")
        let type = Expression<String>("type")
        let path = Expression<String>("path")

        try db.transaction {
            try db.run(searchIndex.drop(ifExists: true))
            try db.run(searchIndex.create { t in
                t.column(id, primaryKey: true)
                t.column(name)
                t.column(type)
                t.column(path)
                t.unique([name, type, path])
            })
        }

        try db.transaction {
            for symbol in module.interface.symbols {
                try db.run(searchIndex.insert(or: .ignore,
                    name <- symbol.id.description,
                    type <- symbol.entryType,
                    path <- symbol.route
                ))
            }
        }

        let tokens: XML = #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <Tokens version="1.0">
        \#(module.interface.topLevelSymbols.map { $0.token })
        </Tokens>
        """#

        let tokensURL = docsetURL.appendingPathComponent("Contents/Resources/Tokens.xml")
        try tokens.description.write(to: tokensURL, atomically: true, encoding: .utf8)
    }
}


fileprivate extension Symbol {
    // https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/HeaderDoc/anchors/anchors.html#//apple_ref/doc/uid/TP40001215-CH347
    var symbolType: String {
        let parent = context.compactMap { $0 as? Symbol }.last?.api
        let isClassOrStatic = api.modifiers.contains { $0.name == "class" } || api.modifiers.contains { $0.name == "static" }

        switch api {
        case is Class:
            return "cl"
        case is Structure, is Enumeration:
            return "tdef"
        case is Protocol:
            return "intf"
        case is Function where parent is Protocol && isClassOrStatic:
            return "intfcm"
        case is Function where parent is Protocol:
            return "intfm"
        case is Function where parent is Type && isClassOrStatic:
            return "clm"
        case is Function where parent is Type:
            return "instm"
        case is Function, is Operator:
            return "func"
        case is Variable where parent is Protocol:
            return "intfp"
        case is Variable where parent is Type && isClassOrStatic:
            return "clconst"
        case is Variable where parent is Type:
            return "instp"
        case is Enumeration.Case:
            return "econst"
        default:
            return "data"
        }
    }

    var token: XML {
        let scope = context.compactMap { $0 as? Symbol }.last?.id.description

        return #"""
        <Token>
           <TokenIdentifier>
             <Name>\#(id)</Name>
             <APILanguage>swift</APILanguage>
             <Type>\#(symbolType)</Type>
             <Scope>\#(scope ?? "")</Scope>
           </TokenIdentifier>
        </Token>
        """#
    }

    var route: String {
        if let parent = context.compactMap({ $0 as? Symbol }).last {
            return path(for: parent) + "/index.html" + "#\(id.description.lowercased().replacingOccurrences(of: " ", with: "-"))"
        } else {
            return path(for: self) + "/index.html"
        }
    }
}

fileprivate extension Symbol {
    // https://kapeli.com/docsets#supportedentrytypes
    var entryType: String {
        let parent = context.compactMap { $0 as? Symbol }.last?.api

        switch api {
        case is Class:
            return "Class"
        case is Initializer:
            return "Constructor"
        case is Enumeration:
            return "Enum"
        case is Enumeration.Case:
            return "Value"
        case let type as Type where type.inheritance.contains(where: { $0.hasSuffix("Error") }):
            return "Error"
        case is Function where parent is Type:
            return "Method"
        case is Function:
            return "Function"
        case is Variable where parent is Type:
            return "Property"
        case let variable as Variable where variable.keyword == "let":
            return "Constant"
        case is Variable:
            return "Variable"
        case is Operator:
            return "Operator"
        case is PrecedenceGroup:
            return "Procedure" // FIXME: no direct matching entry type
        case is Protocol:
            return "Protocol"
        case is Structure:
            return "Struct"
        case is Type, is AssociatedType:
            return "Type"
        default:
            return "Entry"
        }
    }
}