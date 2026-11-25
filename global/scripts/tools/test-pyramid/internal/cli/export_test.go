package cli

// TargetArgument exposes targetArgument to the external tests.
func TargetArgument(arguments []string) (string, error) {
	return targetArgument(arguments)
}

// BlockingOverride exposes blockingOverride to the external tests.
func BlockingOverride(value string) (bool, error) {
	return blockingOverride(value)
}

// ResolveTarget exposes resolveTarget to the external tests.
func ResolveTarget(argument string, getenv func(string) string, defaultBranch func() string) string {
	return resolveTarget(argument, getenv, defaultBranch)
}

// ReportDirectory exposes reportDirectory to the external tests.
func ReportDirectory(root, path string) string {
	return reportDirectory(root, path)
}

// Neutralize exposes neutralize to the external tests.
func Neutralize(message string) string {
	return neutralize(message)
}
