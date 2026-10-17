-- Система управління проєктами в корпорації. PostgreSQL.
-- Вимоги: відділи й працівники; клієнти та проєкти зі статусами;
-- команди з ролями; етапи проєктів; завдання зі статусом, пріоритетом і виконавцем;
-- коментарі, облік часу та мітки завдань. Усього 15 сутностей.
-- Виконавець завдання має входити до команди проєкту.
-- Проєкти, завдання й коментарі: soft delete та автоматичний аудит редактора/часу.
-- M:N: проєкти–працівники, завдання–мітки. Решта зв'язків — 1:N.
-- 3НФ: довідники окремо; списків у полях і збереженого обчислюваного прогресу немає.
-- Запуск один раз у порожній БД; нижче також приклади використання всіх процедур.

BEGIN;
CREATE SCHEMA pm;
SET search_path TO pm, public;

CREATE TABLE departments (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name varchar(100) NOT NULL UNIQUE
);

CREATE TABLE employees (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    department_id integer NOT NULL REFERENCES departments(id),
    full_name varchar(150) NOT NULL,
    email varchar(150) NOT NULL UNIQUE
);

CREATE TABLE clients (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name varchar(150) NOT NULL,
    email varchar(150) NOT NULL UNIQUE
);

CREATE TABLE project_statuses (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name varchar(50) NOT NULL UNIQUE
);

CREATE TABLE project_roles (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name varchar(50) NOT NULL UNIQUE
);

CREATE TABLE projects (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    client_id integer NOT NULL REFERENCES clients(id),
    status_id integer NOT NULL REFERENCES project_statuses(id),
    name varchar(150) NOT NULL CHECK (length(trim(name)) > 0),
    start_date date NOT NULL,
    end_date date,
    CHECK (end_date IS NULL OR end_date >= start_date),
    is_deleted boolean NOT NULL DEFAULT false,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_by integer NOT NULL REFERENCES employees(id)
);

CREATE TABLE project_members (
    project_id integer NOT NULL REFERENCES projects(id),
    employee_id integer NOT NULL REFERENCES employees(id),
    role_id integer NOT NULL REFERENCES project_roles(id),
    PRIMARY KEY (project_id, employee_id)
);

CREATE TABLE milestones (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    project_id integer NOT NULL REFERENCES projects(id),
    name varchar(150) NOT NULL,
    due_date date NOT NULL
);

CREATE TABLE task_statuses (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name varchar(50) NOT NULL UNIQUE,
    is_done boolean NOT NULL DEFAULT false
);

CREATE TABLE priorities (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name varchar(50) NOT NULL UNIQUE
);

CREATE TABLE tasks (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    project_id integer NOT NULL REFERENCES projects(id),
    assignee_id integer NOT NULL REFERENCES employees(id),
    status_id integer NOT NULL REFERENCES task_statuses(id),
    priority_id integer NOT NULL REFERENCES priorities(id),
    title varchar(200) NOT NULL CHECK (length(trim(title)) > 0),
    due_date date,
    FOREIGN KEY (project_id, assignee_id) REFERENCES project_members(project_id, employee_id),
    is_deleted boolean NOT NULL DEFAULT false,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_by integer NOT NULL REFERENCES employees(id)
);

CREATE TABLE comments (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    task_id integer NOT NULL REFERENCES tasks(id),
    author_id integer NOT NULL REFERENCES employees(id),
    body text NOT NULL CHECK (length(trim(body)) > 0),
    is_deleted boolean NOT NULL DEFAULT false,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_by integer NOT NULL REFERENCES employees(id)
);

CREATE TABLE time_entries (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    task_id integer NOT NULL REFERENCES tasks(id),
    employee_id integer NOT NULL REFERENCES employees(id),
    work_date date NOT NULL,
    hours numeric(4,2) NOT NULL CHECK (hours > 0 AND hours <= 24)
);

CREATE TABLE tags (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name varchar(50) NOT NULL UNIQUE
);

CREATE TABLE task_tags (
    task_id integer NOT NULL REFERENCES tasks(id),
    tag_id integer NOT NULL REFERENCES tags(id),
    PRIMARY KEY (task_id, tag_id)
);

CREATE INDEX ix_tasks_project_due ON tasks USING btree(project_id, due_date)
WHERE NOT is_deleted;
CREATE INDEX ix_clients_name_hash ON clients USING hash(name);
COMMIT;

BEGIN;
SET search_path TO pm, public;

CREATE FUNCTION fn_actor() RETURNS integer LANGUAGE plpgsql AS $$
DECLARE actor integer := nullif(current_setting('pm.actor_id', true), '')::integer;
BEGIN
    IF actor IS NULL OR NOT EXISTS (SELECT 1 FROM employees WHERE id = actor) THEN
        RAISE EXCEPTION 'Set a valid actor with CALL sp_set_actor(employee_id)';
    END IF;
    RETURN actor;
END $$;

CREATE PROCEDURE sp_set_actor(p_employee integer) LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM employees WHERE id = p_employee) THEN
        RAISE EXCEPTION 'Employee not found';
    END IF;
    PERFORM set_config('pm.actor_id', p_employee::text, true);
END $$;

CREATE FUNCTION fn_stamp_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := clock_timestamp();
    NEW.updated_by := fn_actor();
    RETURN NEW;
END $$;
CREATE TRIGGER tr_projects_stamp BEFORE INSERT OR UPDATE ON projects
FOR EACH ROW EXECUTE FUNCTION fn_stamp_change();
CREATE TRIGGER tr_tasks_stamp BEFORE INSERT OR UPDATE ON tasks
FOR EACH ROW EXECUTE FUNCTION fn_stamp_change();
CREATE TRIGGER tr_comments_stamp BEFORE INSERT OR UPDATE ON comments
FOR EACH ROW EXECUTE FUNCTION fn_stamp_change();

CREATE FUNCTION fn_require_active_parent() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME IN ('tasks', 'project_members', 'milestones') THEN
        PERFORM 1 FROM projects WHERE id = NEW.project_id AND NOT is_deleted FOR SHARE;
    ELSE
        PERFORM 1 FROM tasks t JOIN projects p ON p.id = t.project_id
        WHERE t.id = NEW.task_id AND NOT t.is_deleted AND NOT p.is_deleted FOR SHARE OF t, p;
    END IF;
    IF NOT FOUND THEN RAISE EXCEPTION 'Parent does not exist or is soft deleted'; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER tr_tasks_parent BEFORE INSERT OR UPDATE ON tasks
FOR EACH ROW EXECUTE FUNCTION fn_require_active_parent();
CREATE TRIGGER tr_members_parent BEFORE INSERT OR UPDATE ON project_members
FOR EACH ROW EXECUTE FUNCTION fn_require_active_parent();
CREATE TRIGGER tr_milestones_parent BEFORE INSERT OR UPDATE ON milestones
FOR EACH ROW EXECUTE FUNCTION fn_require_active_parent();
CREATE TRIGGER tr_comments_parent BEFORE INSERT OR UPDATE ON comments
FOR EACH ROW EXECUTE FUNCTION fn_require_active_parent();
CREATE TRIGGER tr_time_parent BEFORE INSERT OR UPDATE ON time_entries
FOR EACH ROW EXECUTE FUNCTION fn_require_active_parent();
CREATE TRIGGER tr_tags_parent BEFORE INSERT OR UPDATE ON task_tags
FOR EACH ROW EXECUTE FUNCTION fn_require_active_parent();

CREATE FUNCTION fn_project_progress(p_project integer) RETURNS numeric
LANGUAGE sql STABLE AS $$
    SELECT coalesce(round(100.0 * count(*) FILTER (WHERE s.is_done)
                        / nullif(count(*), 0), 2), 0)
    FROM tasks t JOIN task_statuses s ON s.id = t.status_id
    JOIN projects p ON p.id = t.project_id
    WHERE t.project_id = p_project AND NOT t.is_deleted AND NOT p.is_deleted;
$$;

CREATE VIEW v_projects AS
SELECT p.*, c.name AS client_name, s.name AS status_name,
       fn_project_progress(p.id) AS progress_percent
FROM projects p JOIN clients c ON c.id = p.client_id
JOIN project_statuses s ON s.id = p.status_id WHERE NOT p.is_deleted;
CREATE VIEW v_tasks AS
SELECT t.*, e.full_name AS assignee_name, s.name AS status_name, pr.name AS priority_name
FROM tasks t JOIN projects p ON p.id = t.project_id
JOIN employees e ON e.id = t.assignee_id
JOIN task_statuses s ON s.id = t.status_id JOIN priorities pr ON pr.id = t.priority_id
WHERE NOT t.is_deleted AND NOT p.is_deleted;
CREATE VIEW v_comments AS
SELECT c.* FROM comments c JOIN v_tasks t ON t.id = c.task_id WHERE NOT c.is_deleted;
CREATE VIEW v_project_members AS
SELECT m.*, e.full_name, r.name AS role_name FROM project_members m
JOIN v_projects p ON p.id = m.project_id JOIN employees e ON e.id = m.employee_id
JOIN project_roles r ON r.id = m.role_id;
CREATE VIEW v_time_entries AS
SELECT w.* FROM time_entries w JOIN v_tasks t ON t.id = w.task_id;
CREATE VIEW v_employees AS SELECT * FROM employees;
CREATE VIEW v_clients AS SELECT * FROM clients;

CREATE PROCEDURE sp_create_project(p_client integer, p_name text, p_start date,
                                  INOUT p_id integer DEFAULT NULL)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO projects(client_id, status_id, name, start_date)
    VALUES(p_client, (SELECT id FROM project_statuses WHERE name = 'Active'), p_name, p_start)
    RETURNING id INTO p_id;
END $$;
CREATE PROCEDURE sp_rename_project(p_id integer, p_name text) LANGUAGE plpgsql AS $$
BEGIN
    UPDATE projects SET name = p_name WHERE id = p_id AND NOT is_deleted;
    IF NOT FOUND THEN RAISE EXCEPTION 'Active project not found'; END IF;
END $$;
CREATE PROCEDURE sp_add_member(p_project integer, p_employee integer, p_role integer)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO project_members VALUES(p_project, p_employee, p_role);
END $$;
CREATE PROCEDURE sp_create_task(p_project integer, p_employee integer, p_priority integer,
                               p_title text, p_due date, INOUT p_id integer DEFAULT NULL)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO tasks(project_id, assignee_id, status_id, priority_id, title, due_date)
    VALUES(p_project, p_employee, (SELECT id FROM task_statuses WHERE name = 'Todo'),
           p_priority, p_title, p_due) RETURNING id INTO p_id;
END $$;
CREATE PROCEDURE sp_update_task(p_id integer, p_title text, p_status integer)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE tasks SET title = p_title, status_id = p_status WHERE id = p_id AND NOT is_deleted;
    IF NOT FOUND THEN RAISE EXCEPTION 'Active task not found'; END IF;
END $$;
CREATE PROCEDURE sp_add_comment(p_task integer, p_body text, INOUT p_id integer DEFAULT NULL)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO comments(task_id, author_id, body) VALUES(p_task, fn_actor(), p_body)
    RETURNING id INTO p_id;
END $$;
CREATE PROCEDURE sp_edit_comment(p_id integer, p_body text) LANGUAGE plpgsql AS $$
BEGIN
    UPDATE comments SET body = p_body WHERE id = p_id AND NOT is_deleted;
    IF NOT FOUND THEN RAISE EXCEPTION 'Active comment not found'; END IF;
END $$;
CREATE PROCEDURE sp_log_time(p_task integer, p_date date, p_hours numeric)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO time_entries(task_id, employee_id, work_date, hours)
    VALUES(p_task, fn_actor(), p_date, p_hours);
END $$;

CREATE PROCEDURE sp_delete_project(p_id integer) LANGUAGE plpgsql AS $$
BEGIN
    UPDATE projects SET is_deleted = true WHERE id = p_id AND is_deleted <> true;
    IF NOT FOUND THEN RAISE EXCEPTION 'Record missing or already in requested state'; END IF;
END $$;

CREATE PROCEDURE sp_restore_project(p_id integer) LANGUAGE plpgsql AS $$
BEGIN
    UPDATE projects SET is_deleted = false WHERE id = p_id AND is_deleted <> false;
    IF NOT FOUND THEN RAISE EXCEPTION 'Record missing or already in requested state'; END IF;
END $$;

CREATE PROCEDURE sp_delete_task(p_id integer) LANGUAGE plpgsql AS $$
BEGIN
    UPDATE tasks SET is_deleted = true WHERE id = p_id AND is_deleted <> true;
    IF NOT FOUND THEN RAISE EXCEPTION 'Record missing or already in requested state'; END IF;
END $$;

CREATE PROCEDURE sp_restore_task(p_id integer) LANGUAGE plpgsql AS $$
BEGIN
    UPDATE tasks SET is_deleted = false WHERE id = p_id AND is_deleted <> false;
    IF NOT FOUND THEN RAISE EXCEPTION 'Record missing or already in requested state'; END IF;
END $$;

CREATE PROCEDURE sp_delete_comment(p_id integer) LANGUAGE plpgsql AS $$
BEGIN
    UPDATE comments SET is_deleted = true WHERE id = p_id AND is_deleted <> true;
    IF NOT FOUND THEN RAISE EXCEPTION 'Record missing or already in requested state'; END IF;
END $$;

CREATE PROCEDURE sp_restore_comment(p_id integer) LANGUAGE plpgsql AS $$
BEGIN
    UPDATE comments SET is_deleted = false WHERE id = p_id AND is_deleted <> false;
    IF NOT FOUND THEN RAISE EXCEPTION 'Record missing or already in requested state'; END IF;
END $$;
COMMIT;

BEGIN;
SET search_path TO pm, public;
INSERT INTO departments(name) VALUES ('Engineering'), ('Management');
INSERT INTO employees(department_id, full_name, email) VALUES
(1, 'Andrii Kovalenko', 'andrii@example.com'), (2, 'Olena Bondar', 'olena@example.com');
INSERT INTO clients(name, email) VALUES ('Example Corporation', 'client@example.com');
INSERT INTO project_statuses(name) VALUES ('Active'), ('Completed');
INSERT INTO project_roles(name) VALUES ('Manager'), ('Developer');
INSERT INTO task_statuses(name, is_done) VALUES ('Todo', false), ('In progress', false), ('Done', true);
INSERT INTO priorities(name) VALUES ('Normal'), ('High');
INSERT INTO tags(name) VALUES ('backend'), ('documentation');
CALL sp_set_actor(1);
CALL sp_create_project(1, 'Corporate portal', DATE '2026-10-01', NULL);
CALL sp_add_member(1, 1, 2);
CALL sp_add_member(1, 2, 1);
INSERT INTO milestones(project_id, name, due_date) VALUES (1, 'First release', '2026-12-01');
CALL sp_create_task(1, 1, 1, 'Design database', DATE '2026-11-01', NULL);
CALL sp_add_comment(1, 'Initial design is ready', NULL);
CALL sp_log_time(1, DATE '2026-10-17', 2.5);
INSERT INTO task_tags VALUES (1, 1);
COMMIT;

BEGIN;
SET search_path TO pm, public;
CALL sp_set_actor(1);
DO $$
DECLARE p integer; t integer; c integer;
BEGIN
    CALL sp_create_project(1, 'SQL example', CURRENT_DATE, p);
    CALL sp_rename_project(p, 'SQL example renamed');
    CALL sp_add_member(p, 1, 2);
    CALL sp_create_task(p, 1, 1, 'Example task', CURRENT_DATE, t);
    CALL sp_update_task(t, 'Finished task', 3);
    CALL sp_add_comment(t, 'Example comment', c);
    CALL sp_edit_comment(c, 'Updated comment');
    CALL sp_log_time(t, CURRENT_DATE, 1.5);
    RAISE NOTICE 'Progress: %', fn_project_progress(p);
    CALL sp_delete_comment(c);
    CALL sp_restore_comment(c);
    CALL sp_delete_task(t);
    CALL sp_restore_task(t);
    CALL sp_delete_project(p);
    CALL sp_restore_project(p);
END $$;
SELECT * FROM v_projects;
SELECT * FROM v_tasks;
SELECT * FROM v_comments;
SELECT * FROM v_project_members;
SELECT * FROM v_time_entries;
SELECT * FROM v_employees;
SELECT * FROM v_clients;
EXPLAIN SELECT * FROM tasks
WHERE project_id = 1 AND NOT is_deleted ORDER BY due_date;
EXPLAIN SELECT * FROM clients WHERE name = 'Example Corporation';
ROLLBACK;
