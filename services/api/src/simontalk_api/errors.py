class APIError(Exception):
    def __init__(self, status: int, code: str, message: str):
        self.status = status
        self.code = code
        self.message = message


def unauthorized():
    return APIError(401, "unauthorized", "登录已失效，请重新登录。")
