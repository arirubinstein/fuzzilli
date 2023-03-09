// Copyright 2019-2022 Google LLC
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

import Fuzzilli

// swift run FuzzilliCli --profile=xs --jobs=4 --storagePath=./results --resume --inspect=history --timeout=600 $MODDABLE/build/bin/mac/debug/xst

fileprivate let StressXSGC = CodeGenerator("StressXSGC", input: .function()) { b, f in
    guard let arguments = b.randCallArguments(for: f) else { return }

    let index = b.loadInt(1)
    let end = b.loadInt(128)
    let gc = b.reuseOrLoadBuiltin("gc")
	b.callFunction(gc, withArgs: [index])
	b.buildWhileLoop(index, .lessThan, end) {
        b.callFunction(f, withArgs: arguments)
		b.unary(.PostInc, index)
		let result = b.callFunction(gc, withArgs: [index])
		b.buildIfElse(result, ifBody: {
			b.loopBreak();
		}, elseBody: {
		});
	}
}

fileprivate let HardenGenerator = CodeGenerator("HardenGenerator", input: .object()) { b, obj in
	let lockdown = b.reuseOrLoadBuiltin("lockdown")
	let harden = b.reuseOrLoadBuiltin("harden")

	b.callFunction(lockdown, withArgs: [])
	b.callFunction(harden, withArgs: [obj])
}

fileprivate let ExampleGenerator = RecursiveCodeGenerator("ExampleGenerator") { b in
	let code = b.buildCodeString() {
		b.buildRecursive(block: 1, of: 2)
	}
	let resolveHook = b.buildPlainFunction(with: .parameters(n: 2)) { _ in
		b.buildRecursive(block: 2, of: 2)
	}
}


fileprivate let CompartmentGenerator = RecursiveCodeGenerator("CompartmentGenerator") { b in
	let compartmentConstructor = b.reuseOrLoadBuiltin("Compartment");

	var endowments = [String: Variable]()		// may be used as endowments argument or globalLexicals
	var moduleMap = [String: Variable]()
	var options = [String: Variable]()

	for _ in 0..<Int.random(in: 1...4) {
		let propertyName = b.genPropertyNameForWrite()
		endowments[propertyName] = b.randVar()
	}
	var endowmentsObject = b.createObject(with: endowments)

//@@ populate a moduleMap
	let moduleMapObject = b.createObject(with: moduleMap)
	let resolveHook = b.buildPlainFunction(with: .parameters(n: 2)) { _ in
		b.buildRecursive(block: 1, of: 4)
		b.doReturn(b.randVar())
	}
	let moduleMapHook = b.buildPlainFunction(with: .parameters(n: 1)) { _ in
		b.buildRecursive(block: 2, of: 4)
		b.doReturn(b.randVar())
	}
	let loadNowHook = b.dup(moduleMapHook)
	let loadHook = b.buildAsyncFunction(with: .parameters(n: 1)) { _ in
		b.buildRecursive(block: 3, of: 4)
		b.doReturn(b.randVar())
	}
	options["resolveHook"] = resolveHook;
	options["moduleMapHook"] = moduleMapHook;
	options["loadNowHook"] = loadNowHook;
	options["loadHook"] = loadHook;

	if (Int.random(in: 0...100) < 50) {
		options["globalLexicals"] = endowmentsObject
		endowmentsObject = b.createObject(with: [:])
	}
	let optionsObject = b.createObject(with: options)

	let compartment = b.construct(compartmentConstructor, withArgs: [endowmentsObject, moduleMapObject, optionsObject])

	if (Int.random(in: 0...100) < 50) {
		let code = b.buildCodeString() {
			b.buildRecursive(block: 4, of: 4)
		}
		b.callMethod("evaluate", on: compartment, withArgs: [code])
	}
}

//const y = new StaticModuleRecord({ source:`
//	export const b = "b";
//`});



/*
The inputs to this aren't filtered to jsCompartment but seem to be any just .object()
That's not very useful, so leaving this disabled until that is sorted out

fileprivate let CompartmentEvaluateGenerator = CodeGenerator("CompartmentEvaluateGenerator", input: .jsCompartment) { b, target in
	let code = b.codeString() {
		b.buildRecursive()
	}
	b.callMethod("evaluate", on: target, withArgs: [code])
}
*/

let xsProfile = Profile(
    processArgs: { randomize in
        ["-f"]
    },

    processEnv: ["UBSAN_OPTIONS":"handle_segv=0"],

    maxExecsBeforeRespawn: 1000,

    timeout: 250,

    codePrefix: """
                """,

    codeSuffix: """
                gc();
                """,

    ecmaVersion: ECMAScriptVersion.es6,

    crashTests: ["fuzzilli('FUZZILLI_CRASH', 0)", "fuzzilli('FUZZILLI_CRASH', 1)", "fuzzilli('FUZZILLI_CRASH', 2)"],

    additionalCodeGenerators: [
        (StressXSGC,    10),
        (HardenGenerator, 5),
        (CompartmentGenerator, 5),
    ],

    additionalProgramTemplates: WeightedList<ProgramTemplate>([]),

    disabledCodeGenerators: [],

    additionalBuiltins: [
        "gc"                  : .function([.plain(.number)] => .undefined),
        "print"               : .function([.string] => .undefined),
        "placeholder"         : .function([] => .undefined),

		// hardened javascript
		"harden"              : .function([.plain(.anything)] => .undefined),
		"lockdown"            : .function([] => .undefined) ,
		"petrify"             : .function([.plain(.anything)] => .undefined),
		"mutabilities"        : .function([.plain(.anything)] => .object())
    ]
)
