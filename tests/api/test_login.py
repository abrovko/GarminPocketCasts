"""POST /user/login - {email, password, scope} -> {token, uuid}.

Auth.mc's whole recovery path turns on the status code: a 401 from
/user/login is unambiguously "these credentials are wrong" and drops the
stored password, where a 401 from any authenticated endpoint only means the
token expired and is retried once. If this endpoint ever answers 400 for bad
credentials instead, a mistyped password stops sending the user to the
sign-in screen and starts looking like a network fault.
"""


def test_login_returns_a_token(api, shape):
    # `api` has already logged in; asserting on it here checks the shape of
    # what came back rather than paying for a second login.
    assert isinstance(api.token, str) and api.token


def test_login_response_shape(anon, credentials, shape):
    email, password = credentials
    response = anon.login(email, password)
    assert response.status_code == 200
    body = response.json()

    assert isinstance(body.get("token"), str), "token is no longer a string"
    assert isinstance(body.get("uuid"), str), "uuid is no longer a string"
    shape("user_login", body)


def test_bad_credentials_are_401_not_400(anon):
    """Deliberately uses a bogus address, not the real one with a wrong password.

    Same server-side answer, and it keeps a suite that may run often from
    piling failed logins onto an account that could rate-limit or lock.
    """
    response = anon.login("no-such-user.garminpocketcasts@example.invalid", "not-a-password")
    assert response.status_code == 401, (
        "bad credentials now answer " + str(response.status_code) + ", not 401. "
        "Auth.rejectCredentials() is wired to 401 and will stop clearing the password."
    )
