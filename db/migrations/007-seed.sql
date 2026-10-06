-- Reference data for the first city. Safe to re-run.

INSERT INTO ref.jurisdiction (code, name, state_code, time_zone) VALUES
  ('us-il-chicago', 'Chicago', 'IL', 'America/Chicago')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref.source (jurisdiction_id, code, name, record_kind, provider, external_id, endpoint_url)
SELECT j.jurisdiction_id, v.code, v.name, v.record_kind, 'socrata', v.external_id,
       'https://data.cityofchicago.org/resource/' || v.external_id || '.json'
FROM ref.jurisdiction j
CROSS JOIN (VALUES
  ('chicago-building-permits',  'Chicago Building Permits',  'permit',           'ydr8-5enu'),
  ('chicago-business-licenses', 'Chicago Business Licenses', 'business_license', 'r5kz-chrr')
) AS v (code, name, record_kind, external_id)
WHERE j.code = 'us-il-chicago'
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref.permit_category (code, name, is_early_signal) VALUES
  ('new_construction', 'New construction',            true),
  ('renovation',       'Renovation or alteration',    true),
  ('sign',             'Sign',                        false),
  ('trade',            'Electrical, plumbing, or mechanical only', false),
  ('minor',            'Minor or express repair',     false),
  ('demolition',       'Demolition',                  false),
  ('other',            'Other',                       false)
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref.business_category (code, name) VALUES
  ('food',   'Food service or food retail'),
  ('liquor', 'Liquor'),
  ('other',  'Other')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref.signal_type (code, name) VALUES
  ('buildout_permit',     'Renovation or new-construction permit applied for'),
  ('sign_permit',         'Sign permit applied for'),
  ('license_application', 'Business license application created')
ON CONFLICT (code) DO NOTHING;
