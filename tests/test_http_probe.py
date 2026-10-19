"""Exercita a verificação HTTP localmente, sem EC2 nem credenciais."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import unittest

from integration import wait_for_page


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(500 if self.path == "/error" else 200)
        self.end_headers()
        body = b'<p id="lab-marker">ec2-lab-ready</p>'
        self.wfile.write(b"outra pagina" if self.path == "/wrong" else body)

    def log_message(self, *args):
        pass


class HTTPProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.worker = Thread(target=cls.server.serve_forever, daemon=True)
        cls.worker.start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.worker.join(timeout=2)

    def test_accepts_expected_page(self):
        wait_for_page(self.url + "/ready", 1)

    def test_rejects_wrong_content_even_with_http_200(self):
        with self.assertRaises(AssertionError):
            wait_for_page(self.url + "/wrong", 0.2)

    def test_rejects_http_500_even_with_expected_content(self):
        with self.assertRaises(AssertionError):
            wait_for_page(self.url + "/error", 0.2)
