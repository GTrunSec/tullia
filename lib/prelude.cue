import "struct"

#inputs: struct.MinFields(1) & {
	[string]: {
		match: {...}
		not?:      bool
		optional?: bool
	}
}

#output: {
	success?: {...}
	failure?: {...}
}

inputs:  #inputs
output?: #output

let final_inputs = inputs

#lib: {
	_#io: {
		inputs?: #inputs
		output?: #output
	}

	io: [string]: _#io

	merge: {
		#ios: [..._#io]

		let merged = {
			// Declare these so that we can refer to them directly
			// as we cannot refer to fields of the list comprehension below.
			inputs: _
			output: _

			for io in #ios {
				for k, v in io.inputs {
					inputs: "\(k)": {
						match: or([ for io2 in #ios {io2.inputs[k].match}])

						if v.not != _|_ {
							not: v.not
						}

						if v.optional != _|_ {
							optional: v.optional
						}
					}
				}

				output: {
					io
					inputs: final_inputs
				}.output
			}
		}

		// We cannot use `merged` as the top level directly
		// because its incomplete `inputs` will be checked
		// against `#inputs` due to `inputs: #inputs` above
		// during computation of the list comprehension,
		// at which point `inputs` is empty so it fails.
		inputs: merged.inputs
		output: merged.output
	}
}
