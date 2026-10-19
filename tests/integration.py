#!/usr/bin/env python3
"""Valida uma implantação já existente. Não cria, modifica ou termina recursos."""

import argparse
from datetime import datetime, timedelta, timezone
import ipaddress
import json
from pathlib import Path
import socket
import sys
import time
import unittest
from urllib.error import HTTPError, URLError
from urllib.request import ProxyHandler, build_opener

import boto3
from botocore.config import Config


STAGES = {
    "initial": ("t3.micro", 8, False, True),
    "http": ("t3.micro", 8, True, True),
    "resized": ("t3.small", 10, True, True),
    "cleanup-ready": ("t3.small", 10, True, False),
}


def wait_for_page(url, timeout):
    """Espera pelo bootstrap sem aceitar uma página de erro como sucesso."""
    opener = build_opener(ProxyHandler({}))
    deadline = time.monotonic() + timeout
    last_error = "servidor ainda indisponível"
    while time.monotonic() < deadline:
        try:
            remaining = max(0.1, deadline - time.monotonic())
            with opener.open(url, timeout=min(5, remaining)) as response:
                body = response.read(65536).decode("utf-8", errors="replace")
                if response.status == 200 and 'id="lab-marker">ec2-lab-ready</p>' in body:
                    return
                last_error = f"HTTP {response.status}; conteúdo diferente do esperado"
        except (HTTPError, URLError, OSError) as error:
            last_error = str(error)
        time.sleep(min(3, max(0, deadline - time.monotonic())))
    raise AssertionError(f"A página não ficou pronta em {timeout}s: {last_error}")


class EC2IntegrationTests(unittest.TestCase):
    options = None

    @classmethod
    def setUpClass(cls):
        options = cls.options
        values = json.loads(Path(options.outputs).read_text(encoding="utf-8"))
        cls.outputs = {name: item["value"] for name, item in values.items()}
        cls.expected_type, cls.expected_size, cls.http_enabled, cls.protected = STAGES[options.stage]

        settings = Config(
            connect_timeout=5,
            read_timeout=15,
            retries={"max_attempts": 3, "mode": "standard"},
        )
        session = boto3.Session(region_name=cls.outputs["aws_region"])
        cls.ec2 = session.client("ec2", config=settings)
        cls.cloudwatch = session.client("cloudwatch", config=settings)
        instance_id = cls.outputs["instance_id"]
        print(f"\nEtapa: {options.stage} | instância: {instance_id}", flush=True)
        cls.ec2.get_waiter("instance_status_ok").wait(
            InstanceIds=[instance_id],
            WaiterConfig={"Delay": 10, "MaxAttempts": max(1, options.timeout // 10)},
        )
        cls.instance = cls.ec2.describe_instances(InstanceIds=[instance_id])["Reservations"][0]["Instances"][0]
        cls.group = cls.ec2.describe_security_groups(
            GroupIds=[cls.outputs["security_group_id"]]
        )["SecurityGroups"][0]
        cls.volume = cls.ec2.describe_volumes(
            VolumeIds=[cls.outputs["root_volume_id"]]
        )["Volumes"][0]

    def test_instance_and_network(self):
        self.assertEqual(self.instance["State"]["Name"], "running")
        self.assertEqual(self.instance["InstanceType"], self.expected_type)
        self.assertEqual(self.instance["SubnetId"], self.outputs["subnet_id"])
        self.assertEqual(self.instance["VpcId"], self.outputs["vpc_id"])
        self.assertEqual(self.instance.get("PublicIpAddress"), self.outputs["public_ip"])
        ipaddress.IPv4Address(self.outputs["public_ip"])
        self.assertEqual(
            {group["GroupId"] for group in self.instance["SecurityGroups"]},
            {self.outputs["security_group_id"]},
        )
        self.assertFalse(self.instance.get("KeyName"), "O projeto não deve configurar chave SSH.")

    def test_root_volume(self):
        self.assertEqual(self.volume["Size"], self.expected_size)
        self.assertEqual(self.volume["VolumeType"], "gp3")
        self.assertTrue(self.volume["Encrypted"])
        root = next(
            mapping for mapping in self.instance["BlockDeviceMappings"]
            if mapping["DeviceName"] == self.instance["RootDeviceName"]
        )
        self.assertEqual(root["Ebs"]["VolumeId"], self.outputs["root_volume_id"])
        self.assertTrue(root["Ebs"]["DeleteOnTermination"])
        self.assertTrue(any(
            item["InstanceId"] == self.outputs["instance_id"] and item["State"] == "attached"
            for item in self.volume["Attachments"]
        ))

    def test_only_expected_ingress(self):
        permissions = self.group["IpPermissions"]
        if not self.http_enabled:
            self.assertEqual(permissions, [], "A etapa inicial não deve ter regras de entrada.")
            return
        self.assertEqual(len(permissions), 1)
        rule = permissions[0]
        self.assertEqual((rule["IpProtocol"], rule["FromPort"], rule["ToPort"]), ("tcp", 80, 80))
        expected_cidr = str(ipaddress.IPv4Network(self.options.http_cidr, strict=False))
        self.assertEqual([item["CidrIp"] for item in rule.get("IpRanges", [])], [expected_cidr])
        for source in ("Ipv6Ranges", "UserIdGroupPairs", "PrefixListIds"):
            self.assertEqual(rule.get(source, []), [])

    def test_termination_protection_attribute(self):
        result = self.ec2.describe_instance_attribute(
            InstanceId=self.outputs["instance_id"], Attribute="disableApiTermination"
        )
        self.assertEqual(result["DisableApiTermination"]["Value"], self.protected)

    def test_metadata_and_basic_monitoring(self):
        self.assertEqual(self.instance["MetadataOptions"]["HttpTokens"], "required")
        self.assertEqual(self.instance["MetadataOptions"]["HttpEndpoint"], "enabled")
        self.assertEqual(self.instance["Monitoring"]["State"], "disabled")

    def test_web_access(self):
        # Consulta o endereço atual da API, pois o IPv4 pode mudar após stop/start.
        url = f"http://{self.instance['PublicIpAddress']}"
        if self.http_enabled:
            wait_for_page(url, self.options.timeout)
        else:
            # Complementa a checagem das regras; falha de conexão sozinha não prova a causa.
            try:
                with socket.create_connection((self.instance["PublicIpAddress"], 80), timeout=5):
                    pass
            except OSError:
                return
            self.fail("A porta 80 respondeu na etapa em que deveria estar bloqueada.")

    def test_cloudwatch_cpu_metric(self):
        if not self.options.check_metrics:
            self.skipTest("Use --check-metrics para consultar os pontos de CPU no CloudWatch.")
        end = datetime.now(timezone.utc)
        result = self.cloudwatch.get_metric_statistics(
            Namespace="AWS/EC2",
            MetricName="CPUUtilization",
            Dimensions=[{"Name": "InstanceId", "Value": self.outputs["instance_id"]}],
            StartTime=end - timedelta(minutes=30),
            EndTime=end,
            Period=300,
            Statistics=["Average"],
        )
        self.assertTrue(
            result["Datapoints"],
            "Sem pontos de CPU nos últimos 30 minutos. Aguarde a publicação das métricas e repita.",
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", choices=STAGES, required=True)
    parser.add_argument("--outputs", default="terraform-outputs.json")
    parser.add_argument("--timeout", type=int, default=600, help="Prazo para status checks e, separadamente, HTTP.")
    parser.add_argument("--http-cidr", default="0.0.0.0/0", help="Mesmo CIDR configurado no Terraform.")
    parser.add_argument("--check-metrics", action="store_true")
    options = parser.parse_args()
    if options.timeout < 10:
        parser.error("--timeout deve ser de pelo menos 10 segundos.")
    try:
        ipaddress.IPv4Network(options.http_cidr, strict=False)
    except ValueError as error:
        parser.error(str(error))
    EC2IntegrationTests.options = options
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(EC2IntegrationTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
