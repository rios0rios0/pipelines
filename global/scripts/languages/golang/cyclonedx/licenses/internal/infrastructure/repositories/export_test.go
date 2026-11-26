package repositories

// EmbeddedSPDXSchema is the embedded schema file, for the tests that pin it to its upstream bytes.
func EmbeddedSPDXSchema() []byte {
	return spdxSchema
}
