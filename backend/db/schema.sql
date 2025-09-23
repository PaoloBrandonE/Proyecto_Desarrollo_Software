-- Proyecto: Gestión de denuncias urbanas
-- Motor recomendado: PostgreSQL 14+
-- Nota: Ajustar si se usa otro motor. Opcional: PostGIS para geoespacial.

-- Extensiones útiles
CREATE EXTENSION IF NOT EXISTS citext;
-- CREATE EXTENSION IF NOT EXISTS postgis; -- si usarás geom(Point,4326)

-- Tipos enumerados
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_status') THEN
    CREATE TYPE user_status AS ENUM ('pending', 'active', 'suspended');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_role') THEN
    CREATE TYPE user_role AS ENUM ('citizen', 'authority', 'admin');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'complaint_status') THEN
    CREATE TYPE complaint_status AS ENUM ('created', 'validated', 'in_review', 'in_execution', 'resolved', 'rejected', 'archived');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'evidence_type') THEN
    CREATE TYPE evidence_type AS ENUM ('image', 'video', 'document');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'priority_level') THEN
    CREATE TYPE priority_level AS ENUM ('low', 'medium', 'high');
  END IF;
END $$;

-- Tabla de roles (opcional si se usa enum user_role)
CREATE TABLE IF NOT EXISTS roles (
  id SERIAL PRIMARY KEY,
  code user_role UNIQUE NOT NULL
);

-- Usuarios
CREATE TABLE IF NOT EXISTS users (
  id BIGSERIAL PRIMARY KEY,
  full_name VARCHAR(120) NOT NULL,
  email CITEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  role user_role NOT NULL DEFAULT 'citizen',
  status user_status NOT NULL DEFAULT 'pending',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_users_role ON users(role);
CREATE INDEX IF NOT EXISTS idx_users_status ON users(status);

-- Zonas/sectores (opcional)
CREATE TABLE IF NOT EXISTS zones (
  id SERIAL PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  code VARCHAR(50) UNIQUE,
  parent_id INT REFERENCES zones(id) ON DELETE SET NULL
);

-- Categorías de incidente
CREATE TABLE IF NOT EXISTS incident_categories (
  id SERIAL PRIMARY KEY,
  name VARCHAR(80) NOT NULL UNIQUE,
  description VARCHAR(200)
);

-- Denuncias
CREATE TABLE IF NOT EXISTS complaints (
  id BIGSERIAL PRIMARY KEY,
  reporter_id BIGINT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  title VARCHAR(140) NOT NULL,
  description TEXT NOT NULL,
  category_id INT NOT NULL REFERENCES incident_categories(id) ON DELETE RESTRICT,
  status complaint_status NOT NULL DEFAULT 'created',
  priority priority_level,
  latitude NUMERIC(9,6),
  longitude NUMERIC(9,6),
  address VARCHAR(200),
  zone_id INT REFERENCES zones(id) ON DELETE SET NULL,
  is_public BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at TIMESTAMPTZ
  -- geom geometry(Point,4326) -- si activas PostGIS
);

CREATE INDEX IF NOT EXISTS idx_complaints_reporter ON complaints(reporter_id);
CREATE INDEX IF NOT EXISTS idx_complaints_status ON complaints(status);
CREATE INDEX IF NOT EXISTS idx_complaints_category ON complaints(category_id);
CREATE INDEX IF NOT EXISTS idx_complaints_zone ON complaints(zone_id);
CREATE INDEX IF NOT EXISTS idx_complaints_created_at ON complaints(created_at DESC);
-- Si usas PostGIS: CREATE INDEX idx_complaints_geom ON complaints USING GIST (geom);

-- Evidencias
CREATE TABLE IF NOT EXISTS complaint_evidence (
  id BIGSERIAL PRIMARY KEY,
  complaint_id BIGINT NOT NULL REFERENCES complaints(id) ON DELETE CASCADE,
  url TEXT NOT NULL,
  type evidence_type NOT NULL DEFAULT 'image',
  metadata JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_evidence_complaint ON complaint_evidence(complaint_id);

-- Historial de estados
CREATE TABLE IF NOT EXISTS complaint_status_log (
  id BIGSERIAL PRIMARY KEY,
  complaint_id BIGINT NOT NULL REFERENCES complaints(id) ON DELETE CASCADE,
  from_status complaint_status,
  to_status complaint_status NOT NULL,
  changed_by BIGINT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  comment TEXT,
  changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_statuslog_complaint_changedat ON complaint_status_log(complaint_id, changed_at DESC);

-- Asignaciones
CREATE TABLE IF NOT EXISTS complaint_assignments (
  id BIGSERIAL PRIMARY KEY,
  complaint_id BIGINT NOT NULL REFERENCES complaints(id) ON DELETE CASCADE,
  authority_id BIGINT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  assigned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  unassigned_at TIMESTAMPTZ,
  is_active BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_assignment_active ON complaint_assignments(complaint_id) WHERE (is_active);
CREATE INDEX IF NOT EXISTS idx_assignment_authority ON complaint_assignments(authority_id) WHERE (is_active);

-- Comentarios
CREATE TABLE IF NOT EXISTS complaint_comments (
  id BIGSERIAL PRIMARY KEY,
  complaint_id BIGINT NOT NULL REFERENCES complaints(id) ON DELETE CASCADE,
  author_id BIGINT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  body TEXT NOT NULL,
  is_internal BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_comments_complaint ON complaint_comments(complaint_id);

-- Notificaciones (opcional)
CREATE TABLE IF NOT EXISTS notifications (
  id BIGSERIAL PRIMARY KEY,
  user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  complaint_id BIGINT REFERENCES complaints(id) ON DELETE CASCADE,
  channel VARCHAR(30) NOT NULL DEFAULT 'email',
  template_code VARCHAR(60) NOT NULL,
  payload JSONB,
  delivered_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_notifications_user ON notifications(user_id, created_at DESC);

-- Función para updated_at
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Triggers updated_at
DROP TRIGGER IF EXISTS trg_users_updated_at ON users;
CREATE TRIGGER trg_users_updated_at
BEFORE UPDATE ON users
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_complaints_updated_at ON complaints;
CREATE TRIGGER trg_complaints_updated_at
BEFORE UPDATE ON complaints
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Procedimiento: cambio de estado
CREATE OR REPLACE FUNCTION change_complaint_status(p_complaint_id BIGINT, p_user_id BIGINT,
                                                   p_to_status complaint_status, p_comment TEXT)
RETURNS VOID AS $$
DECLARE v_from complaint_status;
BEGIN
  SELECT status INTO v_from FROM complaints WHERE id = p_complaint_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Complaint % not found', p_complaint_id; END IF;

  -- Permisos mínimos: autoridad o admin
  IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id AND role IN ('authority','admin')) THEN
    RAISE EXCEPTION 'User % not allowed to change status', p_user_id;
  END IF;

  INSERT INTO complaint_status_log (complaint_id, from_status, to_status, changed_by, comment)
  VALUES (p_complaint_id, v_from, p_to_status, p_user_id, p_comment);

  UPDATE complaints
     SET status = p_to_status,
         resolved_at = CASE WHEN p_to_status = 'resolved' THEN now() ELSE resolved_at END,
         updated_at = now()
   WHERE id = p_complaint_id;
END;
$$ LANGUAGE plpgsql;

-- Procedimiento: asignar autoridad
CREATE OR REPLACE FUNCTION assign_authority(p_complaint_id BIGINT, p_authority_id BIGINT, p_by BIGINT)
RETURNS VOID AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_by AND role IN ('authority','admin')) THEN
    RAISE EXCEPTION 'User % not allowed to assign', p_by;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_authority_id AND role = 'authority') THEN
    RAISE EXCEPTION 'Assignee % is not authority', p_authority_id;
  END IF;

  UPDATE complaint_assignments
     SET is_active = FALSE, unassigned_at = now()
   WHERE complaint_id = p_complaint_id AND is_active = TRUE;

  INSERT INTO complaint_assignments (complaint_id, authority_id) VALUES (p_complaint_id, p_authority_id);
END;
$$ LANGUAGE plpgsql;

-- Vistas útiles para dashboard (opcional)
CREATE OR REPLACE VIEW vw_complaints_by_status AS
SELECT status, COUNT(*) AS total
FROM complaints
GROUP BY status;

CREATE OR REPLACE VIEW vw_resolved_durations AS
SELECT id AS complaint_id,
       EXTRACT(EPOCH FROM (resolved_at - created_at)) / 3600.0 AS hours_to_resolve
FROM complaints
WHERE status = 'resolved' AND resolved_at IS NOT NULL;

-- Fin del esquema
