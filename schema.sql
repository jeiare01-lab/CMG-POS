-- CMG People & Pay OS: Supabase schema (Postgres). Scope: Construction & Manufacturing Group, companies PSC, CSI and ABC only.
-- Run in the Supabase SQL editor. Order matters. Review every policy before go-live.
-- Statutory rates live in rate tables, not in code, so a circular change is a data update.

create extension if not exists "pgcrypto";

-- ============ core: employee master (the spine) ============
create type app_role as enum ('employee','supervisor','hr','payroll','lr','chro','admin','hrsup','proc','wh','opshead','cfo');

create table company (id serial primary key, code text unique not null, name text);
insert into company(code) values ('PSC'),('CSI'),('ABC');   -- every employee and payroll row belongs to one of these

create table grade_band (grade text primary key, band_min numeric not null, band_mid numeric not null, band_max numeric not null);
insert into grade_band values ('G2',22000,26000,30000),('G3',26000,31000,36000),('G4',36000,43000,50000),('G5',50000,60000,70000),('G6',80000,98000,115000),('G7',120000,145000,170000),('G8',200000,250000,300000);   -- sample bands; replace with the approved structure

create table employee (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique references auth.users(id),
  emp_no text unique not null,
  full_name text not null,
  company_id int references company(id),
  dept text, section text, title text,   -- BA = company, BU = dept, FG = section (SBU is CMG)
  grade text references grade_band(grade),
  monthly_salary numeric(12,2) not null check (monthly_salary >= 0),
  manager_id uuid references employee(id),
  lattice_layer int not null default 1 check (lattice_layer between 1 and 7),
  date_hired date not null,
  active boolean not null default true,
  app_role app_role not null default 'employee',
  created_at timestamptz default now()
);
create table employee_private (            -- bank, TIN, SSS, PhilHealth, Pag-IBIG: restricted, encrypt at rest
  employee_id uuid primary key references employee(id) on delete cascade,
  bank_account text, tin text, sss_no text, philhealth_no text, pagibig_no text
);

-- helper functions used by RLS
create or replace function me() returns employee language sql stable security definer as
$$ select * from employee where auth_user_id = auth.uid() $$;
create or replace function my_role() returns app_role language sql stable security definer as
$$ select app_role from employee where auth_user_id = auth.uid() $$;
create or replace function is_manager_of(emp uuid) returns boolean language sql stable security definer as
$$ select exists(select 1 from employee e where e.id = emp and e.manager_id = (select id from me())) $$;

-- ============ statutory rate tables ============
create table stat_rate (
  agency text not null check (agency in ('SSS','PHILHEALTH','PAGIBIG')),
  effective_from date not null,
  ee_rate numeric not null, er_rate numeric not null,
  floor_base numeric, cap_base numeric,
  primary key (agency, effective_from)
);
create table tax_bracket (effective_from date not null, over_amt numeric not null, base_tax numeric not null, rate numeric not null, primary key (effective_from, over_amt));
-- SAMPLE values. Confirm against current SSS, PhilHealth, Pag-IBIG and BIR circulars before use.
insert into stat_rate values ('SSS','2025-01-01',0.05,0.10,5000,35000),('PHILHEALTH','2025-01-01',0.025,0.025,10000,100000),('PAGIBIG','2024-02-01',0.02,0.02,null,10000);
insert into tax_bracket values ('2023-01-01',0,0,0),('2023-01-01',250000,0,.15),('2023-01-01',400000,22500,.20),('2023-01-01',800000,102500,.25),('2023-01-01',2000000,402500,.30),('2023-01-01',8000000,2202500,.35);

-- ============ timekeeping & payroll ============
create table pay_cycle (id uuid primary key default gen_random_uuid(), code text unique not null, period_start date not null, period_end date not null,
  status text not null default 'open' check (status in ('open','computed','released')), released_at timestamptz, released_by uuid references employee(id));
create table attendance (id uuid primary key default gen_random_uuid(), cycle_id uuid references pay_cycle(id), employee_id uuid references employee(id),
  absent_days numeric default 0, unpaid_leave_days numeric default 0, late_min numeric default 0, ot_hours numeric default 0, nd_hours numeric default 0,
  unique(cycle_id, employee_id));
create table pay_adjustment (id uuid primary key default gen_random_uuid(), employee_id uuid references employee(id), kind text check (kind in ('earn','ded','salary')),
  label text not null, amount numeric(12,2), new_salary numeric(12,2), source text not null, source_ref text,
  applied_cycle uuid references pay_cycle(id), created_at timestamptz default now());
create table loan (id uuid primary key default gen_random_uuid(), employee_id uuid references employee(id), principal numeric not null, cycles_total int not null, cycles_left int not null, per_cycle numeric(12,2) not null, request_id uuid);
create table payslip (id uuid primary key default gen_random_uuid(), cycle_id uuid references pay_cycle(id), employee_id uuid references employee(id),
  basic numeric(12,2), ot_pay numeric(12,2), nd_pay numeric(12,2), absence_ded numeric(12,2), late_ded numeric(12,2), gross numeric(12,2),
  sss numeric(12,2), philhealth numeric(12,2), pagibig numeric(12,2), wtax numeric(12,2), loan_ded numeric(12,2), other_ded numeric(12,2), net numeric(12,2),
  er_sss numeric(12,2), er_philhealth numeric(12,2), er_pagibig numeric(12,2), flags text[] default '{}', released boolean default false,
  unique(cycle_id, employee_id));

-- ============ hiring (ATS) ============
create table requisition (id text primary key, title text not null, company_id int references company(id), dept text, grade text references grade_band(grade), owner_id uuid references employee(id), headcount int not null, filled int not null default 0, status text default 'open');
create table applicant (id uuid primary key default gen_random_uuid(), req_id text references requisition(id), full_name text not null, source text, expected_salary numeric(12,2),
  stage text not null default 'Applied' check (stage in ('Applied','Screen','Interview','Offer','Hired','Rejected')),
  gwc_get boolean default false, gwc_want boolean default false, gwc_capacity boolean default false, employee_id uuid references employee(id));
-- gate: no Offer without GWC
create or replace function guard_offer() returns trigger language plpgsql as $$
begin
  if new.stage = 'Offer' and not (new.gwc_get and new.gwc_want and new.gwc_capacity) then raise exception 'Offer blocked: GWC not cleared'; end if;
  return new;
end $$;
create trigger trg_guard_offer before insert or update on applicant for each row execute function guard_offer();
-- hire = one transaction: employee, onboarding courses, requisition count
create or replace function hire_applicant(p_applicant uuid) returns uuid language plpgsql security definer as $$
declare a applicant; r requisition; new_emp uuid; begin
  if my_role() not in ('hr','chro','admin') then raise exception 'Not allowed'; end if;
  select * into a from applicant where id = p_applicant; select * into r from requisition where id = a.req_id;
  if a.stage <> 'Offer' then raise exception 'Candidate is not at Offer'; end if;
  if (select count(*) from employee e where e.active and e.company_id = r.company_id) + 1 > coalesce((select plan from headcount_plan hp where hp.company_id = r.company_id and hp.fy = extract(year from now())::int), 1e9)
     and my_role() not in ('chro','admin') then raise exception 'Over approved headcount: CHRO approval needed'; end if;
  insert into employee(emp_no, full_name, company_id, dept, title, grade, monthly_salary, manager_id, date_hired)
    values ('E'||to_char(now(),'YYMMDD')||substr(gen_random_uuid()::text,1,4), a.full_name, r.company_id, r.dept, r.title, r.grade, a.expected_salary, r.owner_id, current_date) returning id into new_emp;
  insert into enrollment(employee_id, course_id) select new_emp, id from course where mandatory;
  update applicant set stage='Hired', employee_id = new_emp where id = p_applicant;
  update requisition set filled = filled + 1 where id = r.id;
  return new_emp;
end $$;

-- ============ learning ============
create table course (id text primary key, title text not null, hours numeric, unlocks_layer int default 0, mandatory boolean default false);
create table enrollment (employee_id uuid references employee(id), course_id text references course(id), progress int default 0 check (progress between 0 and 100), completed_on date, primary key (employee_id, course_id));
create or replace view lattice_readiness as
  select e.id as employee_id, e.lattice_layer, e.lattice_layer + 1 as next_layer,
    coalesce(array_agg(c.title) filter (where c.id is not null and en.completed_on is null), '{}') as missing_courses
  from employee e
  left join course c on c.unlocks_layer > 0 and c.unlocks_layer <= e.lattice_layer + 1
  left join enrollment en on en.employee_id = e.id and en.course_id = c.id
  group by e.id, e.lattice_layer;

-- ============ performance ============
create table company_rock (id text primary key, quarter text not null, title text not null);
create table rock (id uuid primary key default gen_random_uuid(), employee_id uuid references employee(id), quarter text not null, title text not null, pct int default 0 check (pct between 0 and 100), parent_id text references company_rock(id));
create table appraisal (employee_id uuid, cycle text, kpi_score int check (kpi_score between 1 and 5), values_score int check (values_score between 1 and 5), rocks_score numeric(3,2), final_score numeric(3,2),
  rating text, merit_pct numeric, idp text, status text default 'draft' check (status in ('draft','final')), primary key (employee_id, cycle));

-- ============ engagement & CSR ============
create table event (id uuid primary key default gen_random_uuid(), title text, event_date date, company_id int references company(id));
create table event_rsvp (event_id uuid references event(id), employee_id uuid references employee(id), primary key(event_id, employee_id));
create table pulse_response (id uuid primary key default gen_random_uuid(), round text, company_id int, q1 int, q2 int, q3 int);   -- no employee_id by design: anonymous
create table recognition (id uuid primary key default gen_random_uuid(), from_id uuid references employee(id), to_id uuid references employee(id), core_value text, message text, created_at timestamptz default now());
create table csr_program (id uuid primary key default gen_random_uuid(), name text, budget numeric, spent numeric default 0, beneficiaries int default 0);
create table csr_volunteer (id uuid primary key default gen_random_uuid(), program_id uuid references csr_program(id), employee_id uuid references employee(id), hours numeric check (hours > 0), logged_on date default current_date);

-- ============ total rewards ============
create table merit_proposal (id uuid primary key default gen_random_uuid(), employee_id uuid references employee(id), cycle text, rating text, from_salary numeric(12,2), to_salary numeric(12,2), pct numeric,
  status text default 'Pending' check (status in ('Pending','Approved','Rejected')), decided_by uuid references employee(id));
-- approval creates the payroll adjustment (applies when the cycle releases)
create or replace function on_merit_approved() returns trigger language plpgsql security definer as $$
begin
  if new.status = 'Approved' and old.status = 'Pending' then
    insert into pay_adjustment(employee_id, kind, label, new_salary, source, source_ref) values (new.employee_id,'salary','Merit '||new.pct||'%',new.to_salary,'Total Rewards',new.id::text);
  end if; return new;
end $$;
create trigger trg_merit_approved after update on merit_proposal for each row execute function on_merit_approved();

-- ============ self-service ============
create table request (id uuid primary key default gen_random_uuid(), employee_id uuid references employee(id), type text check (type in ('Overtime','Vacation leave','Sick leave','Unpaid leave','Company loan','Document')),
  hours numeric, days numeric, amount numeric, months int, detail text, status text default 'Pending' check (status in ('Pending','Approved','Declined')), decided_by uuid references employee(id), created_at timestamptz default now());
create table benefit_enrollment (employee_id uuid primary key references employee(id), hmo_dependents int default 0);
create table leave_balance (employee_id uuid primary key references employee(id), vacation numeric default 10, sick numeric default 5);

-- ============ labor relations ============
create table offense (code text primary key, name text, category text check (category in ('Minor','Major','Grave')), ladder text[] not null);
create table disc_case (id text primary key, employee_id uuid references employee(id), offense_code text references offense(code), facts text, reported_on date not null,
  nte_on date, response_due date generated always as (nte_on + 5) stored, hearing_on date, hearing_held boolean default false,
  stage text default 'Reported' check (stage in ('Reported','NTE issued','Hearing held','Decided')),
  penalty text, suspension_days int, decided_on date, opened_by uuid references employee(id));
-- due process guard: hearing only after the 5-day response window; decision only after hearing
create or replace function guard_case() returns trigger language plpgsql as $$
begin
  if new.stage = 'Hearing held' and (new.nte_on is null or current_date < new.nte_on + 5) then raise exception 'Response window still open'; end if;
  if new.stage = 'Decided' and old.stage <> 'Hearing held' then raise exception 'Decision requires a held hearing'; end if;
  return new;
end $$;
create trigger trg_guard_case before update on disc_case for each row execute function guard_case();
-- suspension -> payroll deduction
create or replace function on_case_decided() returns trigger language plpgsql security definer as $$
declare sal numeric; begin
  if new.stage = 'Decided' and old.stage <> 'Decided' and new.penalty = 'Suspension' then
    select monthly_salary into sal from employee where id = new.employee_id;
    insert into pay_adjustment(employee_id, kind, label, amount, source, source_ref)
      values (new.employee_id,'ded','Suspension '||new.suspension_days||' days · '||new.id, round(sal*12/313*new.suspension_days,2),'Labor Relations',new.id);
  end if; return new;
end $$;
create trigger trg_case_decided after update on disc_case for each row execute function on_case_decided();

-- ============ audit (append-only) ============
create table audit_log (id bigserial primary key, at timestamptz default now(), actor uuid, actor_role app_role, tbl text, row_id text, action text, diff jsonb);
create or replace function audit_trigger() returns trigger language plpgsql security definer as $$
begin
  insert into audit_log(actor, actor_role, tbl, row_id, action, diff)
  values ((select id from me()), my_role(), tg_table_name, coalesce((to_jsonb(new)->>'id'), (to_jsonb(old)->>'id')), tg_op, jsonb_build_object('old', to_jsonb(old), 'new', to_jsonb(new)));
  return coalesce(new, old);
end $$;
do $$ declare t text; begin
  foreach t in array array['employee','payslip','pay_adjustment','loan','merit_proposal','disc_case','appraisal','pay_cycle','applicant'] loop
    execute format('create trigger audit_%1$s after insert or update or delete on %1$s for each row execute function audit_trigger()', t);
  end loop; end $$;
revoke update, delete on audit_log from public, anon, authenticated;

-- ============ row-level security ============
do $$ declare t text; begin
  foreach t in array array['employee','employee_private','attendance','pay_adjustment','loan','payslip','requisition','applicant','enrollment','rock','appraisal','event_rsvp','recognition','csr_volunteer','merit_proposal','request','benefit_enrollment','leave_balance','disc_case','audit_log','pay_cycle','pulse_response','course','company_rock','event','csr_program','offense','grade_band','stat_rate','tax_bracket'] loop
    execute format('alter table %I enable row level security', t);
  end loop; end $$;

-- employee: self, own team, HR/payroll/chro/lr see all
create policy emp_read on employee for select using (auth_user_id = auth.uid() or manager_id = (select id from me()) or my_role() in ('hr','payroll','chro','lr','admin'));
create policy emp_write on employee for all using (my_role() in ('hr','chro','admin')) with check (my_role() in ('hr','chro','admin'));
create policy priv_read on employee_private for select using (employee_id = (select id from me()) or my_role() in ('payroll','chro','admin'));
create policy priv_write on employee_private for all using (my_role() in ('payroll','chro','admin'));

-- payroll: payroll and chro write; employees read only their released payslips; supervisors see nothing
create policy cycle_read on pay_cycle for select using (true);
create policy cycle_write on pay_cycle for all using (my_role() in ('payroll','chro','admin'));
create policy att_read on attendance for select using (employee_id = (select id from me()) or is_manager_of(employee_id) or my_role() in ('hr','payroll','chro','admin'));
create policy att_write on attendance for all using (my_role() in ('payroll','chro','admin'));
create policy slip_read on payslip for select using ((employee_id = (select id from me()) and released) or my_role() in ('payroll','chro','admin'));
create policy slip_write on payslip for all using (my_role() in ('payroll','chro','admin'));
create policy adj_rw on pay_adjustment for all using (my_role() in ('payroll','chro','admin'));
create policy loan_read on loan for select using (employee_id = (select id from me()) or my_role() in ('payroll','hr','chro','admin'));
create policy loan_write on loan for all using (my_role() in ('payroll','chro','admin'));

-- hiring
create policy req_read on requisition for select using (my_role() in ('hr','chro','admin') or owner_id = (select id from me()));
create policy req_write on requisition for all using (my_role() in ('hr','chro','admin'));
create policy app_rw on applicant for all using (my_role() in ('hr','chro','admin'));

-- learning, performance
create policy course_read on course for select using (true);
create policy course_write on course for all using (my_role() in ('hr','chro','admin'));
create policy enr_read on enrollment for select using (employee_id = (select id from me()) or is_manager_of(employee_id) or my_role() in ('hr','chro','admin'));
create policy enr_self on enrollment for update using (employee_id = (select id from me()) or my_role() in ('hr','chro','admin'));
create policy enr_ins on enrollment for insert with check (my_role() in ('hr','chro','admin'));
create policy croc_read on company_rock for select using (true);
create policy croc_write on company_rock for all using (my_role() in ('hr','chro','admin'));
create policy rock_read on rock for select using (employee_id = (select id from me()) or is_manager_of(employee_id) or my_role() in ('hr','chro','admin'));
create policy rock_write on rock for all using (is_manager_of(employee_id) or my_role() in ('hr','chro','admin'));
create policy appr_read on appraisal for select using (employee_id = (select id from me()) or is_manager_of(employee_id) or my_role() in ('hr','chro','admin'));
create policy appr_write on appraisal for all using (is_manager_of(employee_id) or my_role() in ('hr','chro','admin'));

-- engagement, CSR
create policy ev_read on event for select using (true);
create policy ev_write on event for all using (my_role() in ('hr','chro','admin'));
create policy rsvp_rw on event_rsvp for all using (employee_id = (select id from me())) with check (employee_id = (select id from me()));
create policy pulse_ins on pulse_response for insert with check (true);
create policy pulse_read on pulse_response for select using (my_role() in ('hr','chro','admin'));   -- report groups of 3+ only, enforce in the reporting view
create policy rec_read on recognition for select using (true);
create policy rec_ins on recognition for insert with check (from_id = (select id from me()));
create policy csr_read on csr_program for select using (true);
create policy csr_write on csr_program for all using (my_role() in ('hr','chro','admin'));
create policy vol_read on csr_volunteer for select using (true);
create policy vol_ins on csr_volunteer for insert with check (employee_id = (select id from me()));

-- total rewards: employees never see proposals; bands readable by comp roles
create policy band_read on grade_band for select using (my_role() in ('hr','payroll','chro','admin'));
create policy band_write on grade_band for all using (my_role() in ('hr','chro','admin'));
create policy rate_read on stat_rate for select using (true);
create policy tax_read on tax_bracket for select using (true);
create policy merit_read on merit_proposal for select using (my_role() in ('hr','chro','admin'));
create policy merit_insert on merit_proposal for insert with check (my_role() in ('hr','chro','admin'));
create policy merit_decide on merit_proposal for update using (my_role() in ('hr','chro','admin'));

-- self-service: file your own; approver is manager (OT, leave) or HR (loan, documents)
create policy reqs_read on request for select using (employee_id = (select id from me()) or (type in ('Overtime','Vacation leave','Sick leave','Unpaid leave') and is_manager_of(employee_id)) or my_role() in ('hr','chro','admin'));
create policy reqs_ins on request for insert with check (employee_id = (select id from me()));
create policy reqs_decide on request for update using ((type in ('Overtime','Vacation leave','Sick leave','Unpaid leave') and is_manager_of(employee_id)) or my_role() in ('hr','chro','admin'));
create policy ben_rw on benefit_enrollment for all using (employee_id = (select id from me()) or my_role() in ('hr','chro','admin'));
create policy lb_read on leave_balance for select using (employee_id = (select id from me()) or my_role() in ('hr','chro','admin'));

-- labor relations: LR and CHRO only. HR reads. Supervisors and payroll see nothing. Employee sees own case once the NTE is issued.
create policy off_read on offense for select using (my_role() in ('lr','hr','chro','admin'));
create policy off_write on offense for all using (my_role() in ('lr','chro','admin'));
create policy case_read on disc_case for select using (my_role() in ('lr','hr','chro','admin') or (employee_id = (select id from me()) and nte_on is not null));
create policy case_write on disc_case for all using (my_role() in ('lr','chro','admin'));

-- audit: read by HR, LR, CHRO. No update or delete for anyone.
create policy audit_read on audit_log for select using (my_role() in ('hr','lr','chro','admin'));

-- ============ approvals that touch payroll ============
create or replace function on_request_approved() returns trigger language plpgsql security definer as $$
declare cyc uuid; begin
  if new.status = 'Approved' and old.status = 'Pending' then
    select id into cyc from pay_cycle where status = 'open' order by period_start limit 1;
    if new.type = 'Overtime' and cyc is not null then
      insert into attendance(cycle_id, employee_id, ot_hours) values (cyc, new.employee_id, new.hours)
        on conflict (cycle_id, employee_id) do update set ot_hours = attendance.ot_hours + excluded.ot_hours;
    elsif new.type = 'Unpaid leave' and cyc is not null then
      insert into attendance(cycle_id, employee_id, unpaid_leave_days) values (cyc, new.employee_id, new.days)
        on conflict (cycle_id, employee_id) do update set unpaid_leave_days = attendance.unpaid_leave_days + excluded.unpaid_leave_days;
    elsif new.type = 'Vacation leave' then update leave_balance set vacation = greatest(0, vacation - new.days) where employee_id = new.employee_id;
    elsif new.type = 'Sick leave' then update leave_balance set sick = greatest(0, sick - new.days) where employee_id = new.employee_id;
    elsif new.type = 'Company loan' then
      insert into loan(employee_id, principal, cycles_total, cycles_left, per_cycle, request_id) values (new.employee_id, new.amount, new.months*2, new.months*2, round(new.amount/(new.months*2),2), new.id);
    end if;
  end if; return new;
end $$;
create trigger trg_request_approved after update on request for each row execute function on_request_approved();

-- ============ HR KPI cascade (HR Services: individual > supervisor > business unit) ============
create table hr_team (code text primary key, full_name text not null, s4_label text not null, s4_kind text check (s4_kind in ('pct','num','score')), s4_dir text check (s4_dir in ('higher','lower')), s4_target numeric not null);
insert into hr_team values
 ('TAT','TAT · Talent Attraction','Time-to-fill','num','lower',30),
 ('LP','L&P · Learning & Performance','Appraisals on schedule','pct','higher',1),
 ('SD','SD · Service Delivery','Last pay released within 30 days','pct','higher',0.95),
 ('OHSWS','OHSWS · Occ. Health, Safety & Wellness','Claims complete on first filing','pct','higher',0.9),
 ('EE','EE · Employee Engagement','Engagement feedback score (1-5)','score','higher',4.2);
create table hr_team_member (employee_id uuid references employee(id), team text references hr_team(code), is_supervisor boolean default false, primary key (employee_id, team));
create table hr_goal (code text primary key, title text not null);
insert into hr_goal values ('G1','Stronger cash position for Construction & Manufacturing'),('G2','Succession plan in place'),('G3','Productivity and process efficiencies gained'),('G4','Stronger partnerships and joint ventures');
create table hr_service (id text primary key, team text references hr_team(code), goal text references hr_goal(code), name text not null, tat_text text not null, tat_proposed boolean default false, owner_id uuid references employee(id));
create table hr_kpi_log (service_id text references hr_service(id), period text not null, closed int not null default 0, within_tat int not null default 0, first_time_right int not null default 0,
  updated_by uuid references employee(id), updated_at timestamptz default now(), primary key (service_id, period),
  check (within_tat <= closed and first_time_right <= closed));
create table hr_team_outcome (team text references hr_team(code), period text, value numeric, primary key (team, period));
create table hr_bu_input (period text primary key, satisfaction numeric check (satisfaction between 1 and 5));
create table hr_kpi_weight (key text primary key, weight numeric not null);
insert into hr_kpi_weight values ('S1',35),('S2',25),('S3',15),('S4',25),('TAT',20),('LP',20),('SD',20),('OHSWS',20),('EE',20);

-- roll-ups: nothing typed at the top that does not trace back to a service log
create or replace view v_owner_kpi as
  select s.owner_id, l.period, sum(l.closed) closed, sum(l.within_tat)::numeric / nullif(sum(l.closed),0) as i1_on_time, sum(l.first_time_right)::numeric / nullif(sum(l.closed),0) as i2_ftr,
         count(*) filter (where not s.tat_proposed)::numeric / count(*) as i3_tat_agreed
  from hr_service s left join hr_kpi_log l on l.service_id = s.id group by s.owner_id, l.period;
create or replace view v_team_kpi as
  select s.team, l.period, sum(l.within_tat)::numeric / nullif(sum(l.closed),0) as s1_on_time, sum(l.first_time_right)::numeric / nullif(sum(l.closed),0) as s2_ftr,
         count(distinct s.id) filter (where not s.tat_proposed)::numeric / count(distinct s.id) as s3_tat_agreed
  from hr_service s left join hr_kpi_log l on l.service_id = s.id group by s.team, l.period;
create or replace view v_bu_kpi as
  select l.period, sum(l.within_tat)::numeric / nullif(sum(l.closed),0) as b1_sla, sum(l.first_time_right)::numeric / nullif(sum(l.closed),0) as b2_ftr,
         (select count(*) filter (where not tat_proposed)::numeric / count(*) from hr_service) as b3_tat_agreed
  from hr_kpi_log l group by l.period;
create or replace view v_goal_kpi as
  select s.goal, l.period, count(distinct s.id) services, sum(l.within_tat)::numeric / nullif(sum(l.closed),0) as on_time
  from hr_service s left join hr_kpi_log l on l.service_id = s.id group by s.goal, l.period;

-- access by team level: members log their own services, supervisors log any service in their team, HR logs all, others read only
create or replace function is_team_supervisor(t text) returns boolean language sql stable security definer as
$$ select exists(select 1 from hr_team_member m where m.employee_id = (select id from me()) and m.team = t and m.is_supervisor) $$;
alter table hr_service enable row level security; alter table hr_kpi_log enable row level security; alter table hr_team_outcome enable row level security;
alter table hr_bu_input enable row level security; alter table hr_kpi_weight enable row level security; alter table hr_team_member enable row level security;
create policy hs_read on hr_service for select using (my_role() in ('hr','chro','admin') or exists(select 1 from hr_team_member m where m.employee_id=(select id from me())));
create policy hs_claim on hr_service for update using (my_role() in ('hr','chro','admin') or is_team_supervisor(team));
create policy hl_read on hr_kpi_log for select using (my_role() in ('hr','chro','admin') or exists(select 1 from hr_team_member m where m.employee_id=(select id from me())));
create policy hl_write on hr_kpi_log for all using (
  my_role() in ('hr','chro','admin')
  or exists(select 1 from hr_service s where s.id = service_id and (s.owner_id = (select id from me()) or is_team_supervisor(s.team))));
create policy ho_rw on hr_team_outcome for all using (my_role() in ('hr','chro','admin') or is_team_supervisor(team));
create policy hb_rw on hr_bu_input for all using (my_role() in ('hr','chro','admin'));
create policy hw_read on hr_kpi_weight for select using (true);
create policy hw_write on hr_kpi_weight for all using (my_role() in ('hr','chro','admin'));
create policy htm_read on hr_team_member for select using (true);
create policy htm_write on hr_team_member for all using (my_role() in ('hr','chro','admin'));
create trigger audit_hr_kpi_log after insert or update or delete on hr_kpi_log for each row execute function audit_trigger();

-- ============ budget by company (PSC, CSI, ABC) ============
create table budget_line (code text primary key, name text not null, auto_source text);   -- auto_source: 'payroll','rewards' or null (manual)
insert into budget_line values ('wages','Salaries & wages','payroll'),('ot','Overtime','payroll'),('er','Employer SSS, PhilHealth, Pag-IBIG','payroll'),('thirteenth','13th month accrual','payroll'),
 ('benefits','Benefits (HMO, insurance)',null),('recruit','Recruitment',null),('training','Training & development',null),('engage','Engagement',null),('csr','CSR',null),('merit','Merit and promotion reserve','rewards');
create table budget_plan (company_id int references company(id), fy int, line text references budget_line(code), annual_amount numeric(14,2) not null default 0, primary key (company_id, fy, line));
create table headcount_plan (company_id int references company(id), fy int, plan int not null, primary key (company_id, fy));
create table spend_entry (id uuid primary key default gen_random_uuid(), company_id int references company(id), line text references budget_line(code), amount numeric(14,2) not null check (amount > 0), note text, logged_by uuid references employee(id), logged_on date default current_date);
-- actuals: payroll lines come from released payslips; merit from approved proposals; the rest from spend_entry
create or replace view v_budget_actual as
  select e.company_id, extract(year from c.period_end)::int as fy, 'wages' as line, sum(p.gross - p.ot_pay) as actual from payslip p join employee e on e.id = p.employee_id join pay_cycle c on c.id = p.cycle_id where p.released group by 1,2
  union all select e.company_id, extract(year from c.period_end)::int, 'ot', sum(p.ot_pay) from payslip p join employee e on e.id = p.employee_id join pay_cycle c on c.id = p.cycle_id where p.released group by 1,2
  union all select e.company_id, extract(year from c.period_end)::int, 'er', sum(p.er_sss + p.er_philhealth + p.er_pagibig) from payslip p join employee e on e.id = p.employee_id join pay_cycle c on c.id = p.cycle_id where p.released group by 1,2
  union all select e.company_id, extract(year from c.period_end)::int, 'thirteenth', sum(p.basic / 12) from payslip p join employee e on e.id = p.employee_id join pay_cycle c on c.id = p.cycle_id where p.released group by 1,2
  union all select company_id, extract(year from logged_on)::int, line, sum(amount) from spend_entry group by 1,2,3;
alter table budget_line enable row level security; alter table budget_plan enable row level security; alter table headcount_plan enable row level security; alter table spend_entry enable row level security;
create policy bl_read on budget_line for select using (true);
create policy bp_read on budget_plan for select using (my_role() in ('hr','payroll','chro','admin'));
create policy bp_write on budget_plan for all using (my_role() in ('hr','chro','admin'));
create policy hp_read on headcount_plan for select using (my_role() in ('hr','payroll','chro','admin'));
create policy hp_write on headcount_plan for all using (my_role() in ('hr','chro','admin'));
create policy se_read on spend_entry for select using (my_role() in ('hr','payroll','chro','admin'));
create policy se_write on spend_entry for insert with check (my_role() in ('hr','payroll','chro','admin'));
create trigger audit_budget_plan after insert or update or delete on budget_plan for each row execute function audit_trigger();
create trigger audit_headcount_plan after insert or update or delete on headcount_plan for each row execute function audit_trigger();

-- ============ supply chain (PSC, CSI, ABC) ============
insert into budget_line values ('materials','Materials','scm');
create table customer (id text primary key, name text not null, company_id int references company(id));
create table project (id text primary key, company_id int references company(id), customer_id text references customer(id), name text not null,
  contract numeric(14,2) not null check (contract > 0), materials_share numeric(4,3) not null default 0.55, billed numeric(14,2) not null default 0 check (billed >= 0),
  manager_id uuid references employee(id), start_on date, end_on date, rock text, check (billed <= contract));
create table item (sku text primary key, name text not null, uom text not null, category text, unit_price numeric(12,2) not null default 0, reorder_min numeric(12,2) not null default 0);
create table warehouse (id text primary key, company_id int references company(id), name text not null, custodian_id uuid references employee(id));
create table stock_level (warehouse_id text references warehouse(id), sku text references item(sku), qty numeric(12,2) not null default 0 check (qty >= 0), primary key (warehouse_id, sku));
create table vendor (id text primary key, name text not null, status text not null default 'Pending' check (status in ('Pending','Accredited','Suspended')),
  conflict_employee_id uuid references employee(id), license_expiry date);   -- conflict_employee_id: employee with a declared interest in this vendor
create table vendor_doc (vendor_id text references vendor(id), doc text not null, received_on date, primary key (vendor_id, doc));
create table vendor_eval (id uuid primary key default gen_random_uuid(), vendor_id text references vendor(id), q int, d int, p int, c int, r int, evaluated_on date default current_date,
  check (q between 1 and 5 and d between 1 and 5 and p between 1 and 5 and c between 1 and 5 and r between 1 and 5));
create view v_vendor_score as select vendor_id, round(avg(q*0.30 + d*0.25 + p*0.20 + c*0.15 + r*0.10),2) as score, count(*) as evals from vendor_eval group by 1;

create table purchase_request (id text primary key, company_id int references company(id), project_id text references project(id), requester_id uuid not null references employee(id),
  needed_on date, status text not null default 'Draft' check (status in ('Draft','Submitted','Canvass','Awaiting approval','Approved','PO issued','Rejected')), created_at timestamptz default now());
create table pr_line (pr_id text references purchase_request(id) on delete cascade, line_no int, sku text references item(sku), qty numeric(12,2) not null check (qty > 0), est_price numeric(12,2) not null, primary key (pr_id, line_no));
create table quote (pr_id text, line_no int, vendor_id text references vendor(id), price numeric(12,2) not null check (price > 0), lead_days int, awarded boolean default false,
  primary key (pr_id, line_no, vendor_id), foreign key (pr_id, line_no) references pr_line);
create table pr_approval (pr_id text references purchase_request(id), tier text check (tier in ('opshead','cfo')), approver_id uuid not null references employee(id), decision text check (decision in ('approved','rejected')), decided_at timestamptz default now(), primary key (pr_id, tier));
create table purchase_order (id text primary key, pr_id text references purchase_request(id), vendor_id text references vendor(id), company_id int references company(id), project_id text references project(id), issued_on date default current_date);
create table po_line (po_id text references purchase_order(id), line_no int, sku text references item(sku), qty numeric(12,2) not null, price numeric(12,2) not null, received numeric(12,2) not null default 0, check (received >= 0), primary key (po_id, line_no));
create table goods_receipt (id uuid primary key default gen_random_uuid(), po_id text, line_no int, warehouse_id text references warehouse(id), qty numeric(12,2) not null check (qty > 0), received_by uuid references employee(id), received_on date default current_date,
  foreign key (po_id, line_no) references po_line);
create table delivery (id text primary key, warehouse_id text references warehouse(id), project_id text references project(id), sku text references item(sku), qty numeric(12,2) not null check (qty > 0),
  vehicle text, driver_id uuid references employee(id), status text not null default 'Loaded' check (status in ('Loaded','In transit','Delivered')), created_at timestamptz default now());
create table ap_invoice (id text primary key, po_id text references purchase_order(id), vendor_id text references vendor(id), company_id int references company(id), received_value numeric(14,2) not null,
  invoice_amount numeric(14,2), due_on date, status text not null default 'Open' check (status in ('Open','Paid')), paid_by uuid references employee(id));

-- value tier: >= 1,000,000 needs the CMG Operations Head; >= 5,000,000 also the Procurement Committee / CFO
create or replace function pr_value(p text) returns numeric language sql stable as $$
  select coalesce(sum(l.qty * coalesce((select q.price from quote q where q.pr_id = l.pr_id and q.line_no = l.line_no and q.awarded limit 1), l.est_price)), 0) from pr_line l where l.pr_id = p $$;
create or replace function enforce_pr_rules() returns trigger language plpgsql as $$
declare v numeric; req_cfo boolean; ops_ok boolean; cfo_ok boolean;
begin
  if new.status = 'Approved' and old.status is distinct from 'Approved' then
    v := pr_value(new.id); req_cfo := v >= 5000000;
    select exists(select 1 from pr_approval where pr_id = new.id and tier = 'opshead' and decision = 'approved') into ops_ok;
    select exists(select 1 from pr_approval where pr_id = new.id and tier = 'cfo' and decision = 'approved') into cfo_ok;
    if v >= 1000000 and not ops_ok then raise exception 'PR % needs Operations Head approval', new.id; end if;
    if req_cfo and not cfo_ok then raise exception 'PR % needs Procurement Committee / CFO approval', new.id; end if;
  end if;
  return new;
end $$;
create trigger pr_rules before update on purchase_request for each row execute function enforce_pr_rules();
-- segregation of duties: the requester cannot approve their own PR
create or replace function enforce_no_self_approval() returns trigger language plpgsql as $$
begin
  if new.approver_id = (select requester_id from purchase_request where id = new.pr_id) then raise exception 'Requester cannot approve own PR'; end if;
  return new;
end $$;
create trigger pr_no_self_approval before insert on pr_approval for each row execute function enforce_no_self_approval();
-- vendor gate: accredited, not suspended, no declared conflict with the requester or the approver
create or replace function enforce_po_vendor() returns trigger language plpgsql as $$
declare v vendor%rowtype; r uuid;
begin
  select * into v from vendor where id = new.vendor_id;
  if v.status <> 'Accredited' then raise exception 'Vendor % is not accredited', v.id; end if;
  select requester_id into r from purchase_request where id = new.pr_id;
  if v.conflict_employee_id is not null and v.conflict_employee_id in (r, (select approver_id from pr_approval where pr_id = new.pr_id limit 1)) then raise exception 'Declared conflict of interest with vendor %', v.id; end if;
  return new;
end $$;
create trigger po_vendor before insert on purchase_order for each row execute function enforce_po_vendor();
-- goods receipt updates the PO line and stock in one place
create or replace function post_receipt() returns trigger language plpgsql as $$
begin
  update po_line set received = received + new.qty where po_id = new.po_id and line_no = new.line_no and received + new.qty <= qty * 1.0;
  if not found then raise exception 'Receipt exceeds PO quantity'; end if;
  insert into stock_level (warehouse_id, sku, qty) select new.warehouse_id, sku, new.qty from po_line where po_id = new.po_id and line_no = new.line_no
    on conflict (warehouse_id, sku) do update set qty = stock_level.qty + excluded.qty;
  return new;
end $$;
create trigger receipt_post after insert on goods_receipt for each row execute function post_receipt();
-- dispatch cannot take stock below zero (stock_level.qty check) and is deducted on insert
create or replace function post_dispatch() returns trigger language plpgsql as $$
begin update stock_level set qty = qty - new.qty where warehouse_id = new.warehouse_id and sku = new.sku; return new; end $$;
create trigger dispatch_post after insert on delivery for each row execute function post_dispatch();
-- three-way match: PO price x received qty vs invoice, within 1%; a variance blocks payment
create or replace function enforce_invoice_match() returns trigger language plpgsql as $$
begin
  if new.status = 'Paid' and old.status = 'Open' then
    if new.invoice_amount is null or abs(new.invoice_amount - new.received_value) > new.received_value * 0.01 then raise exception 'Invoice % does not match the receipt', new.id; end if;
  end if; return new;
end $$;
create trigger ap_match before update on ap_invoice for each row execute function enforce_invoice_match();

-- materials actuals: goods received at PO price, by company and year; merged into the budget view
create or replace view v_materials_actual as
  select po.company_id, extract(year from po.issued_on)::int as fy, 'materials' as line, sum(l.received * l.price) as actual from purchase_order po join po_line l on l.po_id = po.id group by 1,2;
create or replace view v_budget_actual_all as select * from v_budget_actual union all select * from v_materials_actual;
create or replace view v_project_materials as
  select p.id as project_id, p.contract * p.materials_share as materials_budget,
         coalesce(sum(l.received * l.price),0) as received, coalesce(sum((l.qty - l.received) * l.price),0) as on_order
  from project p left join purchase_order po on po.project_id = p.id left join po_line l on l.po_id = po.id group by p.id;

alter table customer enable row level security; alter table project enable row level security; alter table item enable row level security; alter table warehouse enable row level security; alter table stock_level enable row level security;
alter table vendor enable row level security; alter table vendor_doc enable row level security; alter table vendor_eval enable row level security; alter table purchase_request enable row level security; alter table pr_line enable row level security;
alter table quote enable row level security; alter table pr_approval enable row level security; alter table purchase_order enable row level security; alter table po_line enable row level security; alter table goods_receipt enable row level security;
alter table delivery enable row level security; alter table ap_invoice enable row level security;
create policy scm_read_item on item for select using (true);
create policy scm_rw_item on item for all using (my_role() in ('proc','chro','admin'));
create policy scm_write_project on project for all using (my_role() in ('hr','chro','admin','opshead','proc') or manager_id = (select id from me()));
create policy scm_read_customer on customer for select using (my_role() in ('hr','chro','admin','proc','opshead','cfo'));
create policy scm_rw_customer on customer for all using (my_role() in ('hr','chro','admin','opshead','proc'));
create policy scm_read_wh on warehouse for select using (true);
create policy scm_read_stock on stock_level for select using (my_role() in ('hr','chro','admin','proc','wh','opshead','cfo','supervisor'));
create policy scm_read_vendor on vendor for select using (my_role() in ('hr','chro','admin','proc','opshead','cfo'));
create policy scm_rw_vendor on vendor for all using (my_role() in ('proc','chro','admin'));
create policy scm_read_vdoc on vendor_doc for select using (my_role() in ('hr','chro','admin','proc','opshead','cfo'));
create policy scm_rw_vdoc on vendor_doc for all using (my_role() in ('proc','chro','admin'));
create policy scm_read_veval on vendor_eval for select using (my_role() in ('hr','chro','admin','proc','opshead','cfo'));
create policy scm_rw_veval on vendor_eval for all using (my_role() in ('proc','chro','admin'));
create policy scm_read_pr on purchase_request for select using (my_role() in ('hr','chro','admin','proc','wh','opshead','cfo') or requester_id = (select id from me()));
create policy scm_ins_pr on purchase_request for insert with check (requester_id = (select id from me()));
create policy scm_upd_pr on purchase_request for update using (my_role() in ('proc','opshead','cfo','chro','admin') or requester_id = (select id from me()));
create policy scm_read_prl on pr_line for select using (exists(select 1 from purchase_request r where r.id = pr_id));
create policy scm_rw_prl on pr_line for all using (exists(select 1 from purchase_request r where r.id = pr_id and (r.requester_id = (select id from me()) or my_role() in ('proc','chro','admin'))));
create policy scm_read_quote on quote for select using (my_role() in ('proc','opshead','cfo','chro','admin'));
create policy scm_rw_quote on quote for all using (my_role() in ('proc','chro','admin'));
create policy scm_read_appr on pr_approval for select using (my_role() in ('proc','opshead','cfo','chro','admin','hr'));
create policy scm_ins_appr on pr_approval for insert with check (approver_id = (select id from me()) and ((tier = 'opshead' and my_role() = 'opshead') or (tier = 'cfo' and my_role() = 'cfo')));
create policy scm_read_po on purchase_order for select using (my_role() in ('hr','chro','admin','proc','wh','opshead','cfo'));
create policy scm_rw_po on purchase_order for all using (my_role() in ('proc','chro','admin'));
create policy scm_read_pol on po_line for select using (my_role() in ('hr','chro','admin','proc','wh','opshead','cfo'));
create policy scm_rw_pol on po_line for all using (my_role() in ('proc','chro','admin'));
create policy scm_rw_gr on goods_receipt for all using (my_role() in ('wh','proc','chro','admin'));
create policy scm_rw_dlv on delivery for all using (my_role() in ('wh','proc','chro','admin'));
create policy scm_read_ap on ap_invoice for select using (my_role() in ('payroll','cfo','proc','chro','admin'));
create policy scm_rw_ap on ap_invoice for all using (my_role() in ('payroll','cfo','chro','admin'));
create trigger audit_pr after insert or update or delete on purchase_request for each row execute function audit_trigger();
create trigger audit_po after insert or update or delete on purchase_order for each row execute function audit_trigger();
create trigger audit_vendor after insert or update or delete on vendor for each row execute function audit_trigger();
create trigger audit_ap after insert or update or delete on ap_invoice for each row execute function audit_trigger();

-- ============ project management ============
create table project_task (id text primary key, project_id text not null references project(id), name text not null, owner_id uuid not null references employee(id),
  starts_on date not null, ends_on date not null, pct int not null default 0 check (pct between 0 and 100),
  status text not null default 'Not started' check (status in ('Not started','In progress','Blocked','Done')),
  depends_on text references project_task(id), blocked_why text, mat_sku text references item(sku), mat_qty numeric(12,2), pr_id text references purchase_request(id), check (ends_on >= starts_on));
create table project_crew (project_id text references project(id), employee_id uuid references employee(id), allocation int not null check (allocation between 5 and 100), role text default 'Crew', primary key (project_id, employee_id));
create table project_risk (id text primary key, project_id text references project(id), text text not null, severity text check (severity in ('High','Medium','Low')), owner_id uuid references employee(id), is_open boolean default true);
create table project_update (id uuid primary key default gen_random_uuid(), project_id text references project(id), posted_on date default current_date, posted_by uuid references employee(id), note text not null, progress numeric(5,4), rag text check (rag in ('Red','Amber','Green')));
-- a task cannot start or finish before the task it follows is Done
create or replace function enforce_task_dep() returns trigger language plpgsql as $$
begin
  if new.depends_on is not null and (new.status in ('In progress','Done') or new.pct > 0) and not exists(select 1 from project_task d where d.id = new.depends_on and d.status = 'Done') then
    raise exception 'Task % waits on %', new.id, new.depends_on; end if;
  if new.pct >= 100 then new.status := 'Done'; end if;
  return new;
end $$;
create trigger task_dep before insert or update on project_task for each row execute function enforce_task_dep();
-- nobody is allocated past 100% across projects
create or replace function enforce_crew_cap() returns trigger language plpgsql as $$
begin
  if (select coalesce(sum(allocation),0) from project_crew where employee_id = new.employee_id and project_id <> new.project_id) + new.allocation > 100 then
    raise exception 'Employee would pass 100%% allocation'; end if;
  return new;
end $$;
create trigger crew_cap before insert or update on project_crew for each row execute function enforce_crew_cap();
create view v_project_health as
  select p.id as project_id,
    coalesce(sum((t.ends_on - t.starts_on + 1) * t.pct / 100.0) / nullif(sum((t.ends_on - t.starts_on + 1)),0),0) as progress,
    coalesce(sum((t.ends_on - t.starts_on + 1) * least(1, greatest(0, (current_date - t.starts_on + 1)::numeric / nullif((t.ends_on - t.starts_on + 1),0)))) / nullif(sum((t.ends_on - t.starts_on + 1)),0),0) as planned,
    count(*) filter (where t.status <> 'Done' and t.ends_on < current_date) as overdue,
    count(*) filter (where t.status = 'Blocked') as blocked,
    p.billed, p.contract
  from project p left join project_task t on t.project_id = p.id group by p.id;
create view v_project_crew_cost as select c.project_id, sum(e.monthly_salary * c.allocation / 100.0) as monthly_cost from project_crew c join employee e on e.id = c.employee_id group by 1;
alter table project_task enable row level security; alter table project_crew enable row level security; alter table project_risk enable row level security; alter table project_update enable row level security;
create policy pt_read on project_task for select using (my_role() in ('hr','chro','admin','opshead','cfo','proc','wh','supervisor') or owner_id = (select id from me()) or exists(select 1 from project_crew c where c.project_id = project_task.project_id and c.employee_id = (select id from me())));
create policy pt_write on project_task for all using (my_role() in ('hr','chro','admin','opshead') or owner_id = (select id from me()) or exists(select 1 from project p where p.id = project_task.project_id and p.manager_id = (select id from me())));
create policy pc_read on project_crew for select using (my_role() in ('hr','chro','admin','opshead','cfo','proc','wh','supervisor') or employee_id = (select id from me()));
create policy pc_write on project_crew for all using (my_role() in ('hr','chro','admin','opshead') or exists(select 1 from project p where p.id = project_crew.project_id and p.manager_id = (select id from me())));
create policy pr_read on project_risk for select using (my_role() in ('hr','chro','admin','opshead','cfo','proc','wh','supervisor') or exists(select 1 from project_crew c where c.project_id = project_risk.project_id and c.employee_id = (select id from me())));
create policy pr_write on project_risk for all using (my_role() in ('hr','chro','admin','opshead') or exists(select 1 from project p where p.id = project_risk.project_id and p.manager_id = (select id from me())) or exists(select 1 from project_crew c where c.project_id = project_risk.project_id and c.employee_id = (select id from me())));
create policy pu_read on project_update for select using (my_role() in ('hr','chro','admin','opshead','cfo','proc','wh','supervisor') or exists(select 1 from project_crew c where c.project_id = project_update.project_id and c.employee_id = (select id from me())));
create policy pu_write on project_update for insert with check (my_role() in ('hr','chro','admin','opshead') or exists(select 1 from project p where p.id = project_update.project_id and p.manager_id = (select id from me())));
create trigger audit_project_task after insert or update or delete on project_task for each row execute function audit_trigger();
create policy scm_read_core on project for select using (my_role() in ('hr','chro','admin','proc','wh','opshead','cfo','supervisor','payroll') or exists(select 1 from project_crew c where c.project_id = project.id and c.employee_id = (select id from me())));
create trigger audit_project_crew after insert or update or delete on project_crew for each row execute function audit_trigger();

-- my_role() also returns 'admin' for System Administrators: full read/write on setup tables (employee, roles, budget_plan, item, vendor, project),
-- but approvals (pr_approval tiers, payroll release, discipline decisions) stay with the role holders; do not add 'admin' to those policies.
