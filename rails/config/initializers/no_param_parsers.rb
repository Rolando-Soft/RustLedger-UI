# The API reads request bodies itself (as server.py does), so Rails must not parse JSON bodies first.
ActionDispatch::Request.parameter_parsers = {}
