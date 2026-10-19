#!/usr/bin/env python3
"""Explicit operator-only probe. Creates Stripe test resources and one tok_visa invoice.
The supplied restricted test key selects the sandbox. Confirm that sandbox in Stripe
before running. No live keys, real card data or customer email addresses are accepted.
"""
from pathlib import Path
import json,urllib.parse,urllib.request,urllib.error,uuid,os
# Explicit operator probe: creates test resources and pays one test invoice with tok_visa.
# Never used by ordinary CI. No live keys, customer emails or real card data are accepted.
import argparse,sys
parser=argparse.ArgumentParser(description='Probe the Stripe subscription API in an explicitly selected sandbox.')
parser.add_argument('--run-test-objects',action='store_true',help='Explicitly create and cancel test resources in the sandbox selected by the supplied key.')
parser.add_argument('--report',default='.build/stripe-sandbox/probe-report.json',help='Sanitized local report path.')
args=parser.parse_args()
if not args.run_test_objects: parser.error('Use --run-test-objects only after selecting the intended isolated sandbox.')
key=os.environ.get('STRIPE_RESTRICTED_KEY','')
if not key.startswith(('rk_test_', 'rkcs_test_')):
 parser.error('Supply a restricted test-only key through STRIPE_RESTRICTED_KEY; never use live or unrestricted keys.')
folder=Path(args.report).resolve().parent
folder.mkdir(parents=True,exist_ok=True,mode=0o700)
report_path=Path(args.report).resolve()
os.umask(0o077)
report={'mode':'explicit_sandbox','api_version':'2026-08-26.dahlia','checks':[],'customer_created':False,'subscription_created':False,'live_operations':0}
objects={}
def request(method,path,fields=None):
 data=urllib.parse.urlencode(fields).encode() if fields is not None else None
 req=urllib.request.Request('https://api.stripe.com/v1/'+path,data=data,method=method,headers={
  'Authorization':'Bearer '+key,'Stripe-Version':report['api_version'],'Content-Type':'application/x-www-form-urlencoded'})
 try:
  with urllib.request.urlopen(req,timeout=25) as response: value=json.load(response)
 except urllib.error.HTTPError as error:
  value=json.load(error).get('error',{})
  raise RuntimeError(json.dumps({'status':error.code,'code':value.get('code'),'type':value.get('type'),'param':value.get('param')})) from None
 return value

def check(name,condition):
 if not condition: raise AssertionError(name)
 report['checks'].append(name)
 report_path.write_text(json.dumps(report,indent=2))
 print('PASS: '+name,flush=True)

try:
 product=request('POST','products',{'name':'MacMint isolated API acceptance fixture'})
 price=request('POST','prices',{'product':product['id'],'unit_amount':3999,'currency':'usd','recurring[interval]':'year'})
 check('approved recurring Price contract',not price['livemode'] and price['unit_amount']==3999 and price['recurring']['interval']=='year' and price['recurring']['usage_type']=='licensed')
 portal=request('POST','billing_portal/configurations',{'business_profile[headline]':'Manage MacMint test billing',
  'features[subscription_cancel][enabled]':'true','features[subscription_cancel][mode]':'at_period_end',
  'features[payment_method_update][enabled]':'true','features[invoice_history][enabled]':'true','features[subscription_update][enabled]':'false'})
 check('period-end cancellation portal contract',not portal['livemode'] and portal['active'] and portal['features']['subscription_cancel']['mode']=='at_period_end' and not portal['features']['subscription_update']['enabled'])
 checkout=request('POST','checkout/sessions',{'mode':'subscription','line_items[0][price]':price['id'],'line_items[0][quantity]':1,
  'success_url':'https://macmint.co/account?checkout=processing','cancel_url':'https://macmint.co/account?checkout=cancelled',
  'payment_method_collection':'always','subscription_data[trial_period_days]':3,'integration_identifier':'macmint_probe_'+uuid.uuid4().hex[:8].translate(str.maketrans('0123456789','abcdefghij'))})
 objects['checkout']=checkout['id']
 lines=request('GET','checkout/sessions/'+checkout['id']+'/line_items')
 check('annual Checkout trial total and line-item contract',not checkout['livemode'] and checkout['amount_total']==0 and checkout['currency']=='usd' and lines['data'][0]['price']['id']==price['id'])
 # End the trial explicitly to test the first paid invoice without a clock or a multi-day wait.
 report['test_clock_used']=False
 customer=request('POST','customers',{'name':'MacMint synthetic sandbox buyer'})
 report['customer_created']=True;objects['customer']=customer['id']
 pm=request('POST','payment_methods',{'type':'card','card[token]':'tok_visa'})
 request('POST','payment_methods/'+pm['id']+'/attach',{'customer':customer['id']})
 request('POST','customers/'+customer['id'],{'invoice_settings[default_payment_method]':pm['id']})
 sub=request('POST','subscriptions',{'customer':customer['id'],'items[0][price]':price['id'],'trial_period_days':3})
 objects['subscription']=sub['id'];report['subscription_created']=True
 check('three-day trial and item-level period contract',not sub['livemode'] and sub['status']=='trialing' and sub['trial_end']-sub['trial_start']==3*86400 and sub['items']['data'][0]['current_period_end']==sub['trial_end'])
 invoice=request('GET','invoices/'+sub['latest_invoice'])
 check('invoice parent and line pricing contract',invoice['parent']['subscription_details']['subscription']==sub['id'] and invoice['lines']['data'][0]['pricing']['price_details']['price']==price['id'])
 portal_session=request('POST','billing_portal/sessions',{'customer':customer['id'],'configuration':portal['id'],'return_url':'https://macmint.co/account?billing=returned'})
 check('customer portal session response contract',portal_session['customer']==customer['id'] and portal_session['url'].startswith('https://billing.stripe.com/'))
 request('POST','subscriptions/'+sub['id'],{'trial_end':'now'})
 sub=request('GET','subscriptions/'+sub['id']);invoice=request('GET','invoices/'+sub['latest_invoice'])
 if invoice['status']=='draft':
  request('POST','invoices/'+invoice['id']+'/finalize',{})
  request('POST','invoices/'+invoice['id']+'/pay',{})
  sub=request('GET','subscriptions/'+sub['id']);invoice=request('GET','invoices/'+sub['latest_invoice'])
 check('first annual invoice paid using a Stripe test token',sub['status']=='active' and invoice['status']=='paid' and invoice['amount_paid']==3999 and invoice['lines']['data'][0]['period']['end']==sub['items']['data'][0]['current_period_end'])
 sub=request('POST','subscriptions/'+sub['id'],{'cancel_at_period_end':'true'})
 check('period-end cancellation preserves active paid time',sub['status']=='active' and sub['cancel_at_period_end'])
 request('DELETE','subscriptions/'+sub['id'])
 sub=request('GET','subscriptions/'+sub['id'])
 check('terminal cancellation response contract',sub['status']=='canceled')
 report['status']='passed_provider_contract_probe'
 report['limitations']=['Trial ended manually for this probe; renewal/test-clock advancement and real webhook delivery require separate acceptance.','This does not enable production checkout or certify the intended live business account.']
except Exception as error:
 report['status']='incomplete';report['error']=str(error)
 print('Provider probe incomplete; sanitized details saved to the selected report.',flush=True)
finally:
 if objects.get('subscription'):
  try:
   sub=request('GET','subscriptions/'+objects['subscription'])
   if sub['status']!='canceled': request('DELETE','subscriptions/'+sub['id'])
   report['test_subscription_canceled']=True
  except Exception: report['test_subscription_canceled']=False
 if objects.get('checkout'):
  try: request('POST','checkout/sessions/'+objects['checkout']+'/expire',{});report['unused_checkout_expired']=True
  except Exception: report['unused_checkout_expired']=False
 report_path.write_text(json.dumps(report,indent=2))
 (folder/'provider-objects.json').write_text(json.dumps(objects,indent=2))
if report['status']!='passed_provider_contract_probe': sys.exit(2)
