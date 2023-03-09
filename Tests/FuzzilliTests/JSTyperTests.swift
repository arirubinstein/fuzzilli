// Copyright 2020 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import XCTest
@testable import Fuzzilli

class JSTyperTests: XCTestCase {

    func testBasicTypeInference() {
        let fuzzer = makeMockFuzzer()
        let b = fuzzer.makeBuilder()

        let intVar = b.loadInt(42)
        let floatVar = b.loadFloat(13.37)
        let stringVar = b.loadString("foobar")
        let boolVar = b.loadBool(true)

        XCTAssertEqual(.integer, b.type(of: intVar))
        XCTAssertEqual(.float, b.type(of: floatVar))
        XCTAssertEqual(.string, b.type(of: stringVar))
        XCTAssertEqual(.boolean, b.type(of: boolVar))

        let sum = b.binary(intVar, stringVar, with: .Add)
        XCTAssertEqual(.primitive, b.type(of: sum))

    }

    func testObjectLiterals() {
        let fuzzer = makeMockFuzzer()
        let b = fuzzer.makeBuilder()

        let v = b.loadInt(42)
        let obj = b.buildObjectLiteral { obj in
            obj.addProperty("a", as: v)
            obj.addMethod("m", with: .signature([.integer] => .boolean)) { args in
                let this = args[0]
                // Up to this point, only the "a" property has been installed
                XCTAssertEqual(b.type(of: this), .object(withProperties: ["a"]))
                XCTAssertEqual(b.type(of: args[1]), .integer)
                let notArg = b.unary(.LogicalNot, args[1])
                b.doReturn(notArg)
            }
            obj.addGetter(for: "b") { this in
                // We don't add the "b" property to the |this| type here since it's probably not very useful to access it inside its getter/setter.
                XCTAssertEqual(b.type(of: this), .object(withProperties: ["a"], withMethods: ["m"]))
            }
            obj.addSetter(for: "c") { this, v in
                XCTAssertEqual(b.type(of: this), .object(withProperties: ["a", "b"], withMethods: ["m"]))
            }
        }

        XCTAssertEqual(b.type(of: obj), .object(withProperties: ["a", "b", "c"], withMethods: ["m"]))

        let obj2 = b.buildObjectLiteral { obj in
            obj.addProperty("prop", as: v)
            obj.addElement(0, as: v)
        }

        XCTAssertEqual(b.type(of: obj2), .object(withProperties: ["prop"]))
    }

    func testNestedObjectLiterals() {
        let fuzzer = makeMockFuzzer()
        let b = fuzzer.makeBuilder()

        let v = b.loadInt(42)
        b.buildObjectLiteral { outer in
            outer.addProperty("a", as: v)
            outer.addMethod("m", with: .parameters(n: 1)) { args in
                let this = args[0]
                XCTAssertEqual(b.type(of: this), .object(withProperties: ["a"]))
                b.buildObjectLiteral { inner in
                    inner.addProperty("b", as: v)
                    inner.addMethod("n", with: .parameters(n: 0)) { args in
                        let this = args[0]
                        XCTAssertEqual(b.type(of: this), .object(withProperties: ["b"]))
                    }
                }
            }
            outer.addProperty("c", as: v)
            outer.addMethod("o", with: .parameters(n: 0)) { args in
                let this = args[0]
                XCTAssertEqual(b.type(of: this), .object(withProperties: ["a", "c"], withMethods: ["m"]))
            }
        }
    }

    func testObjectTypeInference() {
        let fuzzer = makeMockFuzzer()
        let b = fuzzer.makeBuilder()

        let intVar = b.loadInt(42)
        let obj = b.createObject(with: ["foo": intVar])
        XCTAssertEqual(b.type(of: obj), .object(withProperties: ["foo"]))

        b.setProperty("bar", of: obj, to: intVar)
        XCTAssertEqual(b.type(of: obj), .object(withProperties: ["foo", "bar"]))

        b.setProperty("baz", of: obj, to: intVar)
        XCTAssertEqual(b.type(of: obj), .object(withProperties: ["foo", "bar", "baz"]))

        let _ = b.deleteProperty("foo", of: obj)
        XCTAssertEqual(b.type(of: obj), .object(withProperties: ["bar", "baz"]))

        // Properties whose values are functions are still treated as properties, not methods.
        let function = b.buildPlainFunction(with: .signature([] => .object())) { params in }
        XCTAssertEqual(b.type(of: function), .functionAndConstructor([] => .object()))
        let obj2 = b.createObject(with: ["foo": intVar, "bar": intVar, "baz": function])
        XCTAssertEqual(b.type(of: obj2), .object(withProperties: ["foo", "bar", "baz"]))
    }

    func testClasses() {
        let fuzzer = makeMockFuzzer()
        let b = fuzzer.makeBuilder()

        let v = b.loadInt(42)
        let cls = b.buildClassDefinition() { cls in
            cls.addConstructor(with: .parameters([.string])) { params in
                let this = params[0]
                XCTAssertEqual(b.type(of: this), .object())
                XCTAssertEqual(b.type(of: params[1]), .string)
                XCTAssertEqual(b.type(of: v), .integer)
                b.reassign(v, to: params[1])
                XCTAssertEqual(b.type(of: v), .string)
            }

            cls.addInstanceProperty("a")
            cls.addInstanceProperty("b")

            cls.addInstanceMethod("f", with: .signature([.float] => .unknown)) { params in
                let this = params[0]
                XCTAssertEqual(b.type(of: this), .object(withProperties: ["a", "b"]))
                XCTAssertEqual(b.type(of: params[1]), .float)
                XCTAssertEqual(b.type(of: v), .integer | .string)
                b.reassign(v, to: params[1])
                XCTAssertEqual(b.type(of: v), .float)
            }

            cls.addInstanceGetter(for: "c") { this in
                XCTAssertEqual(b.type(of: this), .object(withProperties: ["a", "b"], withMethods: ["f"]))
            }

            cls.addInstanceMethod("g", with: .parameters(n: 2)) { params in
                let this = params[0]
                XCTAssertEqual(b.type(of: this), .object(withProperties: ["a", "b", "c"], withMethods: ["f"]))
                XCTAssertEqual(b.type(of: params[1]), .unknown)
                XCTAssertEqual(b.type(of: params[2]), .unknown)
            }

            cls.addStaticProperty("a")
            cls.addStaticProperty("d")

            cls.addStaticMethod("g", with: .parameters(n: 2)) { params in
                let this = params[0]
                XCTAssertEqual(b.type(of: this), .object(withProperties: ["a", "d"]))
                XCTAssertEqual(b.type(of: params[1]), .unknown)
                XCTAssertEqual(b.type(of: params[2]), .unknown)
            }

            cls.addStaticSetter(for: "e") { this, v in
                XCTAssertEqual(b.type(of: this), .object(withProperties: ["a", "d"], withMethods: ["g"]))
            }

            cls.addStaticMethod("h", with: .signature([.integer] => .number)) { params in
                let this = params[0]
                XCTAssertEqual(b.type(of: this), .object(withProperties: ["a", "d", "e"], withMethods: ["g"]))
                XCTAssertEqual(b.type(of: params[1]), .integer)
            }

            cls.addPrivateInstanceMethod("p", with: .parameters(n: 0)) { params in
                let this = params[0]
                XCTAssertEqual(b.type(of: this), .object(withProperties: ["a", "b", "c"], withMethods: ["f", "g"]))
            }

            cls.addPrivateStaticMethod("p", with: .parameters(n: 0)) { params in
                let this = params[0]
                XCTAssertEqual(b.type(of: this), .object(withProperties: ["a", "d", "e"], withMethods: ["g", "h"]))
            }
        }

        XCTAssertEqual(b.type(of: v), .integer | .string | .float)
        XCTAssertEqual(b.type(of: cls), .object(withProperties: ["a", "d", "e"], withMethods: ["g", "h"]) + .constructor([.string] => .object(withProperties: ["a", "b", "c"], withMethods: ["f", "g"])))
    }

    func testClasses2() {
        let fuzzer = makeMockFuzzer()
        let b = fuzzer.makeBuilder()

        let v = b.loadInt(42)
        let s = b.loadString("foo")
        let f = b.loadFloat(13.37)
        b.buildClassDefinition() { cls in
            // Class methods, getters, setters, etc. are treated as conditionally executing blocks.
            cls.addInstanceMethod("m", with: .parameters(n: 0)) { args in
                XCTAssertEqual(b.type(of: v), .integer)

                b.reassign(v, to: b.loadFloat(13.37))

                XCTAssertEqual(b.type(of: v), .float)
            }

            cls.addInstanceGetter(for: "m") { this in
                XCTAssertEqual(b.type(of: v), .integer | .float)

                b.reassign(v, to: b.loadString("bar"))

                XCTAssertEqual(b.type(of: v), .string)
            }

            cls.addStaticMethod("n", with: .parameters(n: 0)) { args in
                XCTAssertEqual(b.type(of: v), .integer | .float | .string)
                XCTAssertEqual(b.type(of: s), .string)

                b.reassign(v, to: b.loadBool(true))
                b.reassign(s, to: b.loadFloat(13.37))

                XCTAssertEqual(b.type(of: v), .boolean)
                XCTAssertEqual(b.type(of: s), .float)
            }

            // The same is true for class static initializers, even though they technically execute unconditionally.
            // However, treating them as executing unconditionally would cause them to overwrite any variable changes
            // performed in preceeding blocks. For example, in this example |s| would be .string after the initializer
            // if it were treated as executing unconditionally, while .string | .float is "more correct".
            cls.addStaticInitializer { this in
                XCTAssertEqual(b.type(of: f), .float)
                XCTAssertEqual(b.type(of: s), .string | .float)

                b.reassign(f, to: b.loadBool(true))
                b.reassign(s, to: b.loadString("baz"))

                XCTAssertEqual(b.type(of: f), .boolean)
                XCTAssertEqual(b.type(of: s), .string)
            }
        }

        XCTAssertEqual(b.type(of: v), .primitive)
        XCTAssertEqual(b.type(of: s), .string | .float)
        XCTAssertEqual(b.type(of: f), .float | .boolean)
    }

    func testNestedClasses() {
        let fuzzer = makeMockFuzzer()
        let b = fuzzer.makeBuilder()

        let outer = b.buildClassDefinition() { cls in
            cls.addInstanceProperty("a")
            cls.addInstanceMethod("m", with: .parameters(n: 0)) { args in
                let inner = b.buildClassDefinition { cls in
                    cls.addInstanceProperty("a")
                    cls.addInstanceProperty("b")
                }
                XCTAssertEqual(b.type(of: inner), .object() + .constructor([] => .object(withProperties: ["a", "b"])))
            }
            cls.addInstanceProperty("c")
        }
        XCTAssertEqual(b.type(of: outer), .object() + .constructor([] => .object(withProperties: ["a", "c"], withMethods: ["m"])))
    }

    func testSubroutineTypes() {
        let fuzzer = makeMockFuzzer()
        let b = fuzzer.makeBuilder()

        let signature1 = [.integer, .number] => .unknown
        let signature2 = [.string, .number] => .unknown

        // Plain functions are both functions and constructors. This might yield interesting results since these function often return a value.
        var f = b.buildPlainFunction(with: .parameters(n: 2)) { params in XCTAssertEqual(b.type(of: params[0]), .unknown); XCTAssertEqual(b.type(of: params[1]), .unknown) }
        XCTAssertEqual(b.type(of: f), .functionAndConstructor([.anything, .anything] => .unknown))

        f = b.buildPlainFunction(with: .signature(signature1)) { params in XCTAssertEqual(b.type(of: params[0]), .integer); XCTAssertEqual(b.type(of: params[1]), .number) }
        XCTAssertEqual(b.type(of: f), .functionAndConstructor(signature1))

        f = b.buildPlainFunction(with: .parameters(n: 2)) { params in XCTAssertEqual(b.type(of: params[0]), .unknown); XCTAssertEqual(b.type(of: params[1]), .unknown) }
        XCTAssertEqual(b.type(of: f), .functionAndConstructor([.anything, .anything] => .unknown))

        // All other function types are just functions...
        f = b.buildArrowFunction(with: .signature(signature2)) { params in XCTAssertEqual(b.type(of: params[0]), .string); XCTAssertEqual(b.type(of: params[1]), .number) }
        XCTAssertEqual(b.type(of: f), .function(signature2))

        f = b.buildGeneratorFunction(with: .signature(signature2)) { params in XCTAssertEqual(b.type(of: params[0]), .string); XCTAssertEqual(b.type(of: params[1]), .number) }
        XCTAssertEqual(b.type(of: f), .function(signature2))

        f = b.buildAsyncFunction(with: .signature(signature1)) { params in XCTAssertEqual(b.type(of: params[0]), .integer); XCTAssertEqual(b.type(of: params[1]), .number) }
        XCTAssertEqual(b.type(of: f), .function(signature1))

        f = b.buildAsyncArrowFunction(with: .signature(signature1)) { params in XCTAssertEqual(b.type(of: params[0]), .integer); XCTAssertEqual(b.type(of: params[1]), .number) }
        XCTAssertEqual(b.type(of: f), .function(signature1))

        f = b.buildAsyncGeneratorFunction(with: .signature(signature1)) { params in XCTAssertEqual(b.type(of: params[0]), .integer); XCTAssertEqual(b.type(of: params[1]), .number) }
        XCTAssertEqual(b.type(of: f), .function(signature1))

        // ... except for constructors, which are just constructors (when they are lifted to JavaScript, they explicitly forbid being called as a function).
        f = b.buildConstructor(with: .signature(signature1)) { params in
            let this = params[0]
            XCTAssertEqual(b.type(of: this), .object())
            XCTAssertEqual(b.type(of: params[1]), .integer)
            XCTAssertEqual(b.type(of: params[2]), .number)
        }
        // TODO we could attempt to infer the return type when we see e.g. property stores. Currently we don't do that though.
        XCTAssertEqual(b.type(of: f), .constructor(signature1))
    }

    func testParameterTypeInference() {
        let fuzzer = makeMockFuzzer()
        let b = fuzzer.makeBuilder()

        let signature = [.string, .object(), .opt(.number)] => .float
        let f = b.buildPlainFunction(with: .signature(signature)) { params in
            XCTAssertEqual(b.type(of: params[0]), .string)
            XCTAssertEqual(b.type(of: params[1]), .object())
            XCTAssertEqual(b.type(of: params[2]), .undefined | .integer | .float)
        }
        XCTAssertEqual(b.type(of: f), .functionAndConstructor(signature))

        let signature2 = [.integer, .anything...] => .float
        let f2 = b.buildPlainFunction(with: .signature(signature2)) { params in
            XCTAssertEqual(b.type(of: params[0]), .integer)
            XCTAssertEqual(b.type(of: params[1]), .object())
        }
        XCTAssertEqual(b.type(of: f2), .functionAndConstructor(signature2))
    }

    func testReassignments() {
        let fuzzer = makeMockFuzzer()
        let b = fuzzer.makeBuilder()

        let v = b.loadInt(42)
        XCTAssertEqual(b.type(of: v), .integer)

        let floatVar = b.loadFloat(13.37)
        b.reassign(v, to: floatVar)
        XCTAssertEqual(b.type(of: v), .float)

        let objVar = b.createObject(with: ["foo": b.loadInt(1337)])
        b.reassign(v, to: objVar)
        XCTAssertEqual(b.type(of: v), .object(withProperties: ["foo"]))
    }

    func testIfElseHandling() {
        let fuzzer = makeMockFuzzer()
        let b = fuzzer.makeBuilder()

        let v = b.loadInt(42)
        let obj = b.createObject(with: ["foo": v])

        b.buildIfElse(v, ifBody: {
            XCTAssertEqual(b.type(of: obj), .object(withProperties: ["foo"]))
            b.setProperty("bar", of: obj, to: v)
            b.setProperty("baz", of: obj, to: v)
            XCTAssertEqual(b.type(of: obj), .object(withProperties: ["foo", "bar", "baz"]))

            XCTAssertEqual(b.type(of: v), .integer)
            let stringVar = b.loadString("foobar")
            b.reassign(v, to: stringVar)
            XCTAssertEqual(b.type(of: v), .string)
        }, elseBody: {
            XCTAssertEqual(b.type(of: obj), .object(withProperties: ["foo"]))
            b.setProperty("bar", of: obj, to: v)
            b.setProperty("bla", of: obj, to: v)
            XCTAssertEqual(b.type(of: obj), .object(withProperties: ["foo", "bar", "bla"]))

            XCTAssertEqual(b.type(of: v), .integer)
            let floatVar = b.loadFloat(13.37)
            b.reassign(v, to: floatVar)
        })

        XCTAssertEqual(b.type(of: v), .string | .float)
        XCTAssertEqual(b.type(of: obj), .object(withProperties: ["foo", "bar"]))

        // Test another program using if/else
        b.reset()

        let v0 = b.loadInt(42)
        let v1 = b.loadInt(42)
        XCTAssertEqual(b.type(of: v0), .integer)
        XCTAssertEqual(b.type(of: v1), .integer)
        b.buildIfElse(v0, ifBody: {
            b.reassign(v0, to: b.loadString("foo"))
            b.reassign(v1, to: b.loadString("foo"))
        }, elseBody: {
            b.reassign(v1, to: b.loadString("bar"))
        })

        XCTAssertEqual(b.type(of: v0), .string | .integer)
        XCTAssertEqual(b.type(of: v1), .string)


        // Test another program using just if
        b.reset()

        let i = b.loadInt(42)
        XCTAssertEqual(b.type(of: i), .integer)
        b.buildIf(i) {
            b.reassign(i, to: b.loadString("foo"))
        }

        XCTAssertEqual(b.type(of: i), .string | .integer)
    }

    func testDeeplyNestedBlocksHandling() {
        let fuzzer = makeMockFuzzer()
        let b = fuzzer.makeBuilder()

        let v = b.loadInt(42)
        XCTAssertEqual(b.type(of: v), .integer)

        b.buildIfElse(v, ifBody: {
            b.buildIfElse(v, ifBody: {
                b.buildIfElse(v, ifBody: {
                    b.reassign(v, to: b.loadString("foo"))
                    XCTAssertEqual(b.type(of: v), .string)
                }, elseBody: {
                    XCTAssertEqual(b.type(of: v), .integer)
                    b.reassign(v, to: b.loadBool(true))
                    XCTAssertEqual(b.type(of: v), .boolean)
                })

                XCTAssertEqual(b.type(of: v), .string | .boolean)
            }, elseBody: {
                XCTAssertEqual(b.type(of: v), .integer)
            })

            XCTAssertEqual(b.type(of: v), .string | .boolean | .integer)
        }, elseBody: {
            XCTAssertEqual(b.type(of: v), .integer)
        })

        XCTAssertEqual(b.type(of: v), .string | .boolean | .integer)
    }

    func testFunctionReassignment() {
        let fuzzer = makeMockFuzzer()
        let b = fuzzer.makeBuilder()

        let signature = [.integer] => .unknown

        func body() {
            let f = b.buildPlainFunction(with: .signature(signature)) {
                params in XCTAssertEqual(b.type(of: params[0]), .integer)
            }
            XCTAssertEqual(b.type(of: f), .functionAndConstructor(signature))
            b.reassign(f, to: b.loadString("foo"))
            XCTAssertEqual(b.type(of: f), .string)
        }

        let v0 = b.loadInt(42)
        b.buildWhileLoop(v0, .lessThan, v0) {
            body()
        }
    }

    func testLoopAndFunctionHandling() {
        let fuzzer = makeMockFuzzer()
        let b = fuzzer.makeBuilder()

        for i in 0..<6 {
            let intVar1 = b.loadInt(0)
            let intVar2 = b.loadInt(100)
            let intVar3 = b.loadInt(42)
            let v = b.loadString("foobar")
            let obj = b.createObject(with: ["foo": v])

            func body() {
                XCTAssertEqual(b.type(of: obj), .object(withProperties: ["foo"]))
                b.setProperty("bar", of: obj, to: intVar1)

                XCTAssertEqual(b.type(of: v), .string)
                let floatVar = b.loadFloat(13.37)
                b.reassign(v, to: floatVar)

                XCTAssertEqual(b.type(of: obj), .object(withProperties: ["foo", "bar"]))
                XCTAssertEqual(b.type(of: v), .float)
            }

            // Select loop type
            switch i {
            case 0:
                b.buildForLoop(intVar1, .lessThan, intVar2, .Add, intVar3) { loopVar in
                    XCTAssertEqual(b.type(of: loopVar), .primitive)
                    body()
                }
            case 1:
                b.buildWhileLoop(intVar1, .lessThan, intVar2) {
                    body()
                }
            case 2:
                b.buildDoWhileLoop(intVar1, .lessThan, intVar2) {
                    body()
                }
            case 3:
                b.buildForInLoop(obj) { loopVar in
                    XCTAssertEqual(b.type(of: loopVar), .string)
                    body()
                }
            case 4:
                b.buildForOfLoop(obj) { loopVar in
                    XCTAssertEqual(b.type(of: loopVar), .unknown)
                    body()
                }
            case 5:
                b.buildPlainFunction(with: .parameters(n: 3)) { _ in
                    body()
                }
            default:
                fatalError()
            }

            XCTAssertEqual(b.type(of: intVar1), .integer)
            XCTAssertEqual(b.type(of: intVar2), .integer)
            XCTAssertEqual(b.type(of: intVar3), .integer)
            XCTAssertEqual(b.type(of: v), .string | .float)
            XCTAssertEqual(b.type(of: obj), .object(withProperties: ["foo"]))

            b.reset()
        }
    }

    func testBuiltinTypeInference() {
        let builtinAType = JSType.integer
        let builtinBType = JSType.object(ofGroup: "B", withProperties: ["foo", "bar"], withMethods: ["m1", "m2"])
        let builtinCType = JSType.function([] => .number)

        let env = MockEnvironment(builtins: [
            "A": builtinAType,
            "B": builtinBType,
            "C": builtinCType
        ])

        let fuzzer = makeMockFuzzer(environment: env)
        let b = fuzzer.makeBuilder()

        let va = b.loadBuiltin("A")
        let vb = b.loadBuiltin("B")
        let vc = b.loadBuiltin("C")

        XCTAssertEqual(b.type(of: va), builtinAType)
        XCTAssertEqual(b.type(of: vb), builtinBType)
        XCTAssertEqual(b.type(of: vc), builtinCType)
    }

    func testPropertyTypeInference() {
        let propFooType = JSType.float
        let propBarType = JSType.function([] => .unknown)
        let propBazType = JSType.object(withProperties: ["a", "b", "c"])
        let propertiesByGroup: [String: [String: JSType]] = [
            "B": [
                "foo": propFooType,
                "bar": propBarType
            ],
            "C": [
                "baz": propBazType,
            ]
        ]

        let builtins: [String: JSType] = [
            "B": .object(ofGroup: "B"),
            "C": .object(ofGroup: "C")
        ]

        let env = MockEnvironment(builtins: builtins, propertiesByGroup: propertiesByGroup)

        let fuzzer = makeMockFuzzer(environment: env)
        let b = fuzzer.makeBuilder()

        // Test program-wide property inference
        b.setType(ofProperty: "a", to: .integer)
        b.setType(ofProperty: "b", to: .object(ofGroup: "B"))

        let aObj = b.loadBuiltin("A")
        XCTAssertEqual(b.type(of: aObj), .unknown)
        let bObj = b.loadBuiltin("B")
        XCTAssertEqual(b.type(of: bObj), .object(ofGroup: "B"))

        // Program-wide property types can always be inferred.
        var p = b.getProperty("a", of: aObj)
        XCTAssertEqual(b.type(of: p), .integer)
        p = b.getProperty("b", of: aObj)
        XCTAssertEqual(b.type(of: p), .object(ofGroup: "B"))
        p = b.getProperty("b", of: bObj)
        XCTAssertEqual(b.type(of: p), .object(ofGroup: "B"))

        // Test inference of property types from the environment
        // .foo and .bar are both known for B objects
        p = b.getProperty("foo", of: bObj)
        XCTAssertEqual(b.type(of: p), propFooType)
        p = b.getProperty("bar", of: bObj)
        XCTAssertEqual(b.type(of: p), propBarType)

        // But .baz is only known on C objects
        p = b.getProperty("baz", of: bObj)
        XCTAssertEqual(b.type(of: p), .unknown)

        let cObj = b.loadBuiltin("C")
        p = b.getProperty("baz", of: cObj)
        XCTAssertEqual(b.type(of: p), propBazType)

        // No property types are known for A objects though.
        p = b.getProperty("foo", of: aObj)
        XCTAssertEqual(b.type(of: p), .unknown)
        p = b.getProperty("bar", of: aObj)
        XCTAssertEqual(b.type(of: p), .unknown)
        p = b.getProperty("baz", of: aObj)
        XCTAssertEqual(b.type(of: p), .unknown)
    }

    func testMethodTypeInference() {
        let m1Signature = [] => .float
        let m2Signature = [.string] => .object(ofGroup: "X")
        let methodsByGroup: [String: [String: Signature]] = [
            "B": [
                "m1": m1Signature,
            ],
            "C": [
                "m2": m2Signature,
            ]
        ]

        let builtins: [String: JSType] = [
            "B": .object(ofGroup: "B"),
            "C": .object(ofGroup: "C")
        ]

        let env = MockEnvironment(builtins: builtins, methodsByGroup: methodsByGroup)

        let fuzzer = makeMockFuzzer(environment: env)
        let b = fuzzer.makeBuilder()

        // Test method signature inference of program-wide methods.
        b.setSignature(ofMethod: "m3", to: [] => .integer)

        let aObj = b.loadBuiltin("A")
        XCTAssertEqual(b.type(of: aObj), .unknown)
        let bObj = b.loadBuiltin("B")
        XCTAssertEqual(b.type(of: bObj), .object(ofGroup: "B"))

        var r = b.callMethod("m3", on: aObj, withArgs: [])
        XCTAssertEqual(b.type(of: r), .integer)
        r = b.callMethod("m3", on: bObj, withArgs: [])
        XCTAssertEqual(b.type(of: r), .integer)

        // Test inference of per-group methods.
        r = b.callMethod("m1", on: bObj, withArgs: [])
        XCTAssertEqual(b.type(of: r), .float)

        r = b.callMethod("m2", on: bObj, withArgs: [])
        XCTAssertEqual(b.type(of: r), .unknown)

        let cObj = b.loadBuiltin("C")
        r = b.callMethod("m2", on: cObj, withArgs: [])
        XCTAssertEqual(b.type(of: r), .object(ofGroup: "X"))
    }

    func testConstructorTypeInference() {
        let aConstructorType = JSType.constructor([.rest(.anything)] => .object(ofGroup: "A"))
        let builtins: [String: JSType] = [
            "A": aConstructorType,
        ]

        let env = MockEnvironment(builtins: builtins)

        let fuzzer = makeMockFuzzer(environment: env)
        let b = fuzzer.makeBuilder()

        let A = b.loadBuiltin("A")
        XCTAssertEqual(b.type(of: A), aConstructorType)

        // For a known constructor, the resulting type can be inferred
        let a = b.construct(A, withArgs: [])
        XCTAssertEqual(b.type(of: a), .object(ofGroup: "A"))

        // For an unknown constructor, the result will be .object()
        let B = b.loadBuiltin("B")
        let b_ = b.construct(B, withArgs: [])
        XCTAssertEqual(b.type(of: b_), .object())

        // For a self-defined constructor, the result will currently also be .object, but we could in theory improve the type inference for these cases
        let C = b.buildConstructor(with: .parameters(n: 2)) { args in
            let this = args[0]
            b.setProperty("foo", of: this, to: args[1])
            b.setProperty("bar", of: this, to: args[2])
        }
        let c = b.construct(C, withArgs: [])
        XCTAssertEqual(b.type(of: c), .object())
    }

    func testReturnTypeInference() {
        let aFunctionType = JSType.function([.rest(.anything)] => .primitive)
        let builtins: [String: JSType] = [
            "a": aFunctionType,
        ]

        let env = MockEnvironment(builtins: builtins)

        let fuzzer = makeMockFuzzer(environment: env)
        let b = fuzzer.makeBuilder()

        let a = b.loadBuiltin("a")
        XCTAssertEqual(b.type(of: a), aFunctionType)

        // For a known function, the resulting type can be inferred
        var r = b.callFunction(a, withArgs: [])
        XCTAssertEqual(b.type(of: r), .primitive)

        // For an unknown function, the result will be .unknown
        let c = b.loadBuiltin("c")
        r = b.callFunction(c, withArgs: [])
        XCTAssertEqual(b.type(of: r), .unknown)
    }

    func testPrimitiveTypesOverride() {
        let env = MockEnvironment(builtins: [:])
        env.intType = .integer + .object(ofGroup: "Number")
        env.floatType = .float + .object(ofGroup: "Number")
        env.booleanType = .boolean + .object(ofGroup: "Number")
        env.stringType = .string + .object(ofGroup: "Number")

        let fuzzer = makeMockFuzzer(environment: env)
        let b = fuzzer.makeBuilder()

        let iv = b.loadInt(42)
        let fv = b.loadFloat(13.37)
        let bv = b.loadBool(true)
        let sv = b.loadString("foobar")

        XCTAssertEqual(b.type(of: iv), env.intType)
        XCTAssertEqual(b.type(of: fv), env.floatType)
        XCTAssertEqual(b.type(of: bv), env.booleanType)
        XCTAssertEqual(b.type(of: sv), env.stringType)
    }

    func testArrayCreation() {
        let env = MockEnvironment(builtins: [:])
        env.arrayType = .object(ofGroup: "Array")

        let fuzzer = makeMockFuzzer(environment: env)
        let b = fuzzer.makeBuilder()

        let a = b.createArray(with: [])
        XCTAssertEqual(b.type(of: a), .object(ofGroup: "Array"))
    }

    func testSuperBinding() {
        let fuzzer = makeMockFuzzer()
        let b = fuzzer.makeBuilder()

        let superclass = b.buildClassDefinition() { cls in
            cls.addConstructor(with: .parameters([.integer])) { params in
                let this = params[0]
                XCTAssertEqual(b.type(of: this), .object())
                XCTAssertEqual(b.currentSuperType(), .object())

                XCTAssertEqual(b.type(of: params[1]), .integer)
            }

            cls.addInstanceProperty("a")

            cls.addInstanceMethod("f", with: .signature([.float] => .string)) { params in
                let this = params[0]
                XCTAssertEqual(b.type(of: this), .object(withProperties: ["a"]))
                XCTAssertEqual(b.currentSuperType(), .object())

                XCTAssertEqual(b.type(of: params[1]), .float)

                b.doReturn(b.loadString("foobar"))
            }
        }

        let superType = JSType.object(withProperties: ["a"], withMethods: ["f"])
        XCTAssertEqual(b.type(of: superclass), .object() + .constructor([.integer] => superType))

        let v = b.loadInt(42)
        let cls = b.buildClassDefinition(withSuperclass: superclass) { cls in
            cls.addInstanceProperty("b", value: v)

            cls.addConstructor(with: .parameters([.string])) { params in
                XCTAssertEqual(b.currentSuperConstructorType(), .object() + .constructor([.integer] => .object(withProperties: ["a"], withMethods: ["f"])))
                let this = params[0]
                XCTAssertEqual(b.type(of: this), .object(withProperties: ["a", "b"], withMethods: ["f"]))
                XCTAssertEqual(b.currentSuperType(), superType)

                b.callSuperConstructor(withArgs: [b.loadFloat(42)])
            }

            cls.addInstanceMethod("g", with: .signature([.anything] => .unknown)) { params in
                let this = params[0]
                XCTAssertEqual(b.type(of: this), .object(withProperties: ["a", "b"], withMethods: ["f"]))
                XCTAssertEqual(b.currentSuperType(), superType)
            }
        }
        XCTAssertEqual(b.type(of: cls), .object() + .constructor([.string] => .object(withProperties: ["a", "b"], withMethods: ["f", "g"])))
    }

    func testBigintTypeInference() {
        let fuzzer = makeMockFuzzer()
        let b = fuzzer.makeBuilder()

        let i1 = b.loadInt(42)
        let i2 = b.loadInt(43)
        XCTAssert(b.type(of: i1).Is(.integer))
        let bi1 = b.loadBigInt(4200000000)
        let bi2 = b.loadBigInt(4300000000)
        XCTAssert(b.type(of: bi1).Is(.bigint))

        for op in UnaryOperator.allCases {
            // Logical operators produce .boolean in any case
            guard op != .LogicalNot else { continue }
            let r1 = b.unary(op, i1)
            XCTAssertFalse(b.type(of: r1).MayBe(.bigint))
            let r2 = b.unary(op, bi1)
            XCTAssert(b.type(of: r2).Is(.bigint))
        }

        for op in BinaryOperator.allCases {
            // Logical operators produce .boolean in any case
            guard op != .LogicOr && op != .LogicAnd else { continue }
            let r1 = b.binary(i1, i2, with: op)
            XCTAssertFalse(b.type(of: r1).MayBe(.bigint))
            let r2 = b.binary(i1, bi2, with: op)
            // This isn't really necessary, as mixing types in this way
            // would lead to an exception in JS. Currently, we handle
            // it like this though.
            XCTAssert(b.type(of: r2).MayBe(.bigint))
            let r3 = b.binary(bi1, bi2, with: op)
            XCTAssert(b.type(of: r3).Is(.bigint))
        }

        for op in BinaryOperator.allCases {
            let i3 = b.loadInt(45)
            let i4 = b.loadInt(46)
            XCTAssert(b.type(of: i3).Is(.integer))
            let bi3 = b.loadBigInt(4200000000)
            let bi4 = b.loadBigInt(4300000000)
            XCTAssert(b.type(of: bi3).Is(.bigint))

            // Logical operators produce .boolean in any case
            guard op != .LogicOr && op != .LogicAnd else { continue }
            b.reassign(i3, to: i4, with: op)
            XCTAssertFalse(b.type(of: i3).MayBe(.bigint))
            b.reassign(i3, to: bi4, with: op)
            // This isn't really necessary, as mixing types in this way
            // would lead to an exception in JS. Currently, we handle
            // it like this though.
            XCTAssert(b.type(of: i3).MayBe(.bigint))
            b.reassign(bi3, to: bi4, with: op)
            XCTAssert(b.type(of: bi3).Is(.bigint))
        }
    }

    func testSwitchStatementHandling() {
        let fuzzer = makeMockFuzzer()
        let b = fuzzer.makeBuilder()

        let v0 = b.loadInt(42)
        let v1 = b.createObject(with: ["foo": v0])
        let v2 = b.getProperty("foo", of: v1)
        let v3 = b.loadInt(1337)
        let v4 = b.loadString("42")

        b.buildSwitch(on: v2) { cases in
            cases.add(v3) {
                XCTAssertEqual(b.type(of: v1), .object(withProperties: ["foo"]))
                b.setProperty("bar", of: v1, to: v0)
                b.setProperty("baz", of: v1, to: v0)
                XCTAssertEqual(b.type(of: v1), .object(withProperties: ["foo", "bar", "baz"]))

                XCTAssertEqual(b.type(of: v0), .integer)
                let stringVar = b.loadString("foobar")
                b.reassign(v0, to: stringVar)
                XCTAssertEqual(b.type(of: v0), .string)
            }
            cases.addDefault {
                XCTAssertEqual(b.type(of: v1), .object(withProperties: ["foo"]))
                b.setProperty("bar", of: v1, to: v0)
                b.setProperty("qux", of: v1, to: v0)
                XCTAssertEqual(b.type(of: v1), .object(withProperties: ["foo", "bar", "qux"]))

                XCTAssertEqual(b.type(of: v0), .integer)
                let boolVal = b.loadBool(false)
                b.reassign(v0, to: boolVal)
                XCTAssertEqual(b.type(of: v0), .boolean)
            }
            cases.add(v4) {
                XCTAssertEqual(b.type(of: v1), .object(withProperties: ["foo"]))
                b.setProperty("bar", of: v1, to: v0)
                b.setProperty("bla", of: v1, to: v0)
                XCTAssertEqual(b.type(of: v1), .object(withProperties: ["foo", "bar", "bla"]))

                XCTAssertEqual(b.type(of: v0), .integer)
                let floatVar = b.loadFloat(13.37)
                b.reassign(v0, to: floatVar)
                XCTAssertEqual(b.type(of: v0), .float)
            }
        }

        XCTAssertEqual(b.type(of: v0), .float | .string | .boolean)
        XCTAssertEqual(b.type(of: v1), .object(withProperties: ["foo", "bar"]))
        XCTAssertEqual(b.type(of: v3), .integer)
        XCTAssertEqual(b.type(of: v4), .string)
    }

    func testSwitchStatementHandling2() {
        let fuzzer = makeMockFuzzer()
        let b = fuzzer.makeBuilder()

        let i1 = b.loadInt(42)
        let i2 = b.loadInt(42)
        b.buildSwitch(on: i1) { cases in
            cases.addDefault() {
                XCTAssertEqual(b.type(of: i1), .integer)
                XCTAssertEqual(b.type(of: i2), .integer)
                b.reassign(i2, to: b.loadString("bar"))
            }
        }

        XCTAssertEqual(b.type(of: i1), .integer)
        XCTAssertEqual(b.type(of: i2), .string)
    }

    func testSwitchStatementHandling3() {
        let fuzzer = makeMockFuzzer()
        let b = fuzzer.makeBuilder()

        let i1 = b.loadInt(42)
        let i2 = b.loadInt(43)
        let i3 = b.loadInt(44)

        let v = b.loadString("foobar")

        b.buildSwitch(on: i1){ cases in
            cases.add(i2) {
                XCTAssertEqual(b.type(of: v), .string)
                b.reassign(v, to: b.loadFloat(13.37))
                XCTAssertEqual(b.type(of: v), .float)
            }

            cases.add(i3) {
                XCTAssertEqual(b.type(of: v), .string)
                b.reassign(v, to: b.loadBool(false))
                XCTAssertEqual(b.type(of: v), .boolean)
            }
        }

        XCTAssertEqual(b.type(of: v), .string | .float | .boolean)
    }

    func testSwitchStatementHandling4() {
        let fuzzer = makeMockFuzzer()
        let b = fuzzer.makeBuilder()

        let i1 = b.loadInt(42)
        XCTAssertEqual(b.type(of: i1), .integer)
        b.buildSwitch(on: i1) { cases in
        }
        XCTAssertEqual(b.type(of: i1), .integer)
    }

    func testDestructObjectTypeInference() {
        let fuzzer = makeMockFuzzer()
        let b = fuzzer.makeBuilder()

        let intVar = b.loadInt(42)
        let obj = b.createObject(with: ["foo": intVar])
        b.setType(ofProperty: "foo", to: .integer)
        XCTAssertEqual(b.type(of: obj), .object(withProperties: ["foo"]))

        b.setProperty("bar", of: obj, to: b.loadString("Hello"))
        b.setType(ofProperty: "bar", to: .string)
        XCTAssertEqual(b.type(of: obj), .object(withProperties: ["foo", "bar"]))

        b.setProperty("baz", of: obj, to: intVar)
        b.setType(ofProperty: "baz", to: .integer)
        XCTAssertEqual(b.type(of: obj), .object(withProperties: ["foo", "bar", "baz"]))

        let outputs = b.destruct(obj, selecting: ["foo", "bar"], hasRestElement: true)
        XCTAssertEqual(b.type(of: outputs[0]), .integer)
        XCTAssertEqual(b.type(of: outputs[1]), .string)
        XCTAssertEqual(b.type(of: outputs[2]), .object())
    }
}
