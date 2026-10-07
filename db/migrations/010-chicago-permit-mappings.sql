-- Chicago's permit vocabulary, mapped onto the common categories and roles.
-- Safe to re-run: existing rows are left alone.

-- Permit types. The Express Permit Program covers many kinds of work, so it is
-- mapped by work type; anything not listed falls back to the row with an empty
-- work type.
INSERT INTO ref.permit_type_map (source_id, permit_type_raw, work_type_raw, permit_category_code)
SELECT s.source_id, v.permit_type_raw, v.work_type_raw, v.category
FROM ref.source s
CROSS JOIN (VALUES
  ('PERMIT - RENOVATION/ALTERATION',  '', 'renovation'),
  ('PERMIT - NEW CONSTRUCTION',       '', 'new_construction'),
  ('PERMIT - SIGNS',                  '', 'sign'),
  ('PERMIT - EASY PERMIT PROCESS',    '', 'minor'),
  ('PERMIT - ELEVATOR EQUIPMENT',     '', 'trade'),
  ('PERMIT - WRECKING/DEMOLITION',    '', 'demolition'),
  ('PERMIT - REINSTATE REVOKED PMT',  '', 'other'),
  ('PERMIT - SCAFFOLDING',            '', 'other'),
  ('PERMIT – EXPRESS PERMIT PROGRAM', '', 'minor'),
  ('PERMIT – EXPRESS PERMIT PROGRAM', 'Nonstructural Interior Work', 'renovation'),
  ('PERMIT – EXPRESS PERMIT PROGRAM', 'Electrical Work',             'trade'),
  ('PERMIT – EXPRESS PERMIT PROGRAM', 'Plumbing Work',               'trade'),
  ('PERMIT – EXPRESS PERMIT PROGRAM', 'Mechanical Work',             'trade'),
  ('PERMIT – EXPRESS PERMIT PROGRAM', 'Fire Alarm System',           'trade'),
  ('PERMIT – EXPRESS PERMIT PROGRAM', 'Communication Equipment',     'trade'),
  ('PERMIT – EXPRESS PERMIT PROGRAM', 'Administrative Change',       'other'),
  ('PERMIT – EXPRESS PERMIT PROGRAM', 'Monthly Maintenance Permit',  'other'),
  ('PERMIT – EXPRESS PERMIT PROGRAM', 'Scaffolding',                 'other'),
  ('PERMIT – EXPRESS PERMIT PROGRAM', 'Other Work',                  'other')
) AS v (permit_type_raw, work_type_raw, category)
WHERE s.code = 'chicago-building-permits'
ON CONFLICT DO NOTHING;

-- Contact types. Chicago uses two generations of labels for the same role
-- (CONTRACTOR-ELECTRICAL and ELECTRICAL CONTRACTOR), so both are listed.
INSERT INTO ref.contact_type_map (source_id, contact_type_raw, role_code, trade)
SELECT s.source_id, v.contact_type_raw, v.role_code, v.trade
FROM ref.source s
CROSS JOIN (VALUES
  ('OWNER',                             'owner',               NULL),
  ('OWNER OCCUPIED',                    'owner',               NULL),
  ('BUILDING OWNER',                    'owner',               NULL),
  ('PARTY WALL OWNER',                  'owner',               NULL),
  ('OWNER AS GENERAL CONTRACTOR',       'owner',               'general'),
  ('OWNER RESPONSIBLE FOR WORK',        'owner',               'general'),
  ('OWNER RESPONSIBLE FOR MASON WORK',  'owner',               'masonry'),
  ('OWNER PERFORMING PLUMBING WORK',    'owner',               'plumbing'),
  ('OWNER AS ARCHITECT & CONTRACTR',    'owner',               'general'),
  ('OWNER AS ARCHITECT',                'owner',               NULL),
  ('TENANT',                            'tenant',              NULL),
  ('APPLICANT',                         'applicant',           NULL),
  ('WEB APPLICANT',                     'applicant',           NULL),
  ('APPLICANT’S REPRESENTATIVE',        'applicant',           NULL),
  ('CONTRACTOR-GENERAL CONTRACTOR',     'contractor',          'general'),
  ('GENERAL CONTRACTOR',                'contractor',          'general'),
  ('CONTRACTOR-ELECTRICAL',             'contractor',          'electrical'),
  ('ELECTRICAL CONTRACTOR',             'contractor',          'electrical'),
  ('CONTRACTOR-PLUMBER/PLUMBING',       'contractor',          'plumbing'),
  ('PLUMBING CONTRACTOR',               'contractor',          'plumbing'),
  ('CONTRACTOR-VENTILATION',            'contractor',          'ventilation'),
  ('OTHER SUBCONTRACTOR (VENTILATION)', 'contractor',          'ventilation'),
  ('CONTRACTOR-REFRIGERATION',          'contractor',          'refrigeration'),
  ('MASONRY CONTRACTOR',                'contractor',          'masonry'),
  ('MASON CONTRACTOR',                  'contractor',          'masonry'),
  ('CONTRACTOR-ELEVATOR',               'contractor',          'elevator'),
  ('SIGN CONTRACTOR',                   'contractor',          'sign'),
  ('PRIVATE ALARM CONTRACTOR',          'contractor',          'alarm'),
  ('TENT CONTRACTOR',                   'contractor',          'tent'),
  ('WRECKING CONTRACTOR',               'contractor',          'wrecking'),
  ('CONTRACTOR-WRECKING',               'contractor',          'wrecking'),
  ('OTHER CONTRACTOR',                  'contractor',          NULL),
  ('ARCHITECT',                         'design_professional', NULL),
  ('SELF CERT ARCHITECT',               'design_professional', NULL),
  ('REGISTERED DESIGN PROFESSIONAL',    'design_professional', NULL),
  ('STRUCTURAL ENGINEER',               'design_professional', NULL),
  ('PROFESSIONAL ENGINEER',             'design_professional', NULL),
  ('EXPEDITOR',                         'expediter',           NULL),
  ('EXPEDITER',                         'expediter',           NULL),
  ('RESIDENTAL REAL ESTATE DEV',        'other',               NULL)
) AS v (contact_type_raw, role_code, trade)
WHERE s.code = 'chicago-building-permits'
ON CONFLICT DO NOTHING;
