#!/usr/bin/env python3
"""Operator-only: create MacMint's plan-page Product, three yearly Prices and three Payment
Links in a Stripe TEST-mode account, then print the `tiers` JSON for the commerce config.

Each link: subscription with a 7-day trial, card always collected, quantity fixed at 1, no
promotion codes, and an after-payment redirect to /welcome?session_id={CHECKOUT_SESSION_ID}.
The key comes from STRIPE_SETUP_KEY (sk_test_/rk_test_ with Products, Prices and Payment
Links write access). Live keys are refused. Never part of CI; nothing secret is printed.
"""
import argparse
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request

API_VERSION = '2026-08-26.dahlia'
TIERS = [('mac1', 1, 3995), ('mac2', 2, 5995), ('mac5', 5, 9995)]

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument('--create-test-links', action='store_true', help='Explicitly create the test-mode objects.')
parser.add_argument('--origin', default='https://macmint.co', help='Website origin for the /welcome redirect (HTTPS, no path).')
args = parser.parse_args()
if not args.create_test_links:
    parser.error('Pass --create-test-links after selecting the intended Stripe sandbox.')
if not re.fullmatch(r'https://[a-z0-9.-]+(:\d+)?', args.origin):
    parser.error('--origin must be an HTTPS origin without a path, for example https://staging.macmint.co')
key = os.environ.get('STRIPE_SETUP_KEY', '')
if not key.startswith(('sk_test_', 'rk_test_')):
    parser.error('Supply a TEST-mode key through STRIPE_SETUP_KEY; live keys are refused.')


def stripe(path, fields):
    request = urllib.request.Request('https://api.stripe.com/v1/' + path, data=urllib.parse.urlencode(fields).encode(), method='POST',
                                     headers={'Authorization': 'Bearer ' + key, 'Stripe-Version': API_VERSION,
                                              'Content-Type': 'application/x-www-form-urlencoded'})
    try:
        with urllib.request.urlopen(request, timeout=25) as response:
            value = json.load(response)
    except urllib.error.HTTPError as error:
        detail = json.load(error).get('error', {})
        raise SystemExit(f"Stripe refused {path}: {detail.get('code') or detail.get('type')} ({detail.get('param')})") from None
    if value.get('livemode') is not False:
        raise SystemExit('Refusing to continue: Stripe reported a live-mode object.')
    return value


product = stripe('products', {'name': 'MacMint Pro', 'description': 'Annual MacMint Pro subscription', 'metadata[macmint]': 'pro'})
tiers = []
for tier, devices, amount in TIERS:
    label = f"{devices} {'Mac' if devices == 1 else 'Macs'}"
    price = stripe('prices', {'product': product['id'], 'currency': 'usd', 'unit_amount': amount, 'recurring[interval]': 'year',
                              'recurring[interval_count]': 1, 'nickname': f'MacMint Pro, Annual, {label}', 'metadata[macmint_tier]': tier})
    link = stripe('payment_links', {
        'line_items[0][price]': price['id'], 'line_items[0][quantity]': 1,
        'line_items[0][adjustable_quantity][enabled]': 'false',
        'subscription_data[trial_period_days]': 7,
        'subscription_data[trial_settings][end_behavior][missing_payment_method]': 'cancel',
        'subscription_data[description]': f'MacMint Pro, Annual, {label}',
        'subscription_data[metadata][macmint_tier]': tier,
        'payment_method_collection': 'always',
        'allow_promotion_codes': 'false',
        'after_completion[type]': 'redirect',
        'after_completion[redirect][url]': args.origin + '/welcome?session_id={CHECKOUT_SESSION_ID}',
        'metadata[macmint_tier]': tier,
    })
    tiers.append(dict(tier=tier, devices=devices, payment_link_id=link['id'], url=link['url'], price_id=price['id'],
                      amount_minor=amount, currency='usd', trial_days=7))
print(json.dumps({'tiers': tiers}, indent=2))
print('Copy these tiers into the commerce config (test mode). Set the top-level price_id to the 1 Mac Price for signed-in purchases.')
