-- =====================================================================
--  BackToMe · Esquema de base de datos
--  PostgreSQL 15+ · Modelo SaaS multi-tenant con Row-Level Security
--  Capstone APT122 · Duoc UC
-- ---------------------------------------------------------------------
--  EJECUCIÓN (una sola vez, sobre una base de datos vacía):
--    createdb backtome
--    psql -U <rol_owner> -d backtome -f backtome_schema.sql
--
--  - Ejecutar con el rol dueño (owner) de la base, NO con backtome_app.
--  - Cambiar la contraseña de backtome_app (sección 2) antes de producción.
--  - El script corre en una transacción: si algo falla, no queda nada a medias.
--
--  USO DESDE NESTJS (en cada petición, dentro de una transacción):
--    BEGIN;
--    SELECT set_config('app.tenant_id',  '<uuid tenant>',  true);
--    SELECT set_config('app.usuario_id', '<uuid usuario>', true);
--    ... consultas de la petición ...
--    COMMIT;
--  El tercer parámetro "true" hace que el valor dure solo esa transacción,
--  así una conexión reutilizada del pool nunca arrastra el tenant anterior.
-- =====================================================================

BEGIN;

-- =====================================================================
-- 1. EXTENSIONES
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid(), digest(), gen_random_bytes()
CREATE EXTENSION IF NOT EXISTS citext;     -- texto sin distinción de mayúsculas (correos, dominios)

-- =====================================================================
-- 2. ROL DE LA APLICACIÓN (con el que se conecta NestJS)
-- =====================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'backtome_app') THEN
    CREATE ROLE backtome_app LOGIN PASSWORD 'CAMBIAR_ESTA_CLAVE'
      NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  END IF;
END $$;

-- =====================================================================
-- 3. FUNCIONES DE CONTEXTO DE SESIÓN
-- =====================================================================
CREATE OR REPLACE FUNCTION app_tenant_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.tenant_id', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION app_usuario_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.usuario_id', true), '')::uuid
$$;

-- =====================================================================
-- 4. TIPOS ENUMERADOS
-- =====================================================================
CREATE TYPE estado_tenant   AS ENUM ('prueba', 'activo', 'suspendido');
CREATE TYPE rol_usuario     AS ENUM ('alumno', 'colaborador', 'operador', 'admin_tenant');
CREATE TYPE estado_objeto   AS ENUM ('en_custodia', 'en_reclamo', 'entregado', 'desechado', 'donado');
CREATE TYPE estado_reclamo  AS ENUM ('pendiente', 'aprobado', 'rechazado');
CREATE TYPE tipo_movimiento AS ENUM ('ingreso', 'traslado', 'entrega', 'desecho', 'donacion');

-- =====================================================================
-- 5. TABLAS
--    Las FK compuestas (columna, tenant_id) impiden a nivel de motor que
--    una fila apunte a un registro de OTRO tenant.
--    tenant_id toma por defecto app_tenant_id(): el backend no necesita
--    enviarlo (inyección automática, HU-02 CA1).
-- =====================================================================

-- 5.1 Organizaciones clientes
CREATE TABLE tenants (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre      text NOT NULL,
  slug        text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9-]{3,50}$'),
  plan        text NOT NULL DEFAULT 'anual',
  estado      estado_tenant NOT NULL DEFAULT 'prueba',
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- 5.2 Dominios de correo por tenant (HU-01: mapeo automático de dominio)
CREATE TABLE tenant_dominios (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenants (id) ON DELETE CASCADE,
  dominio     citext NOT NULL UNIQUE CHECK (dominio ~ '^[a-z0-9-]+(\.[a-z0-9-]+)+$'),
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- 5.3 Sedes o campus
CREATE TABLE sedes (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL DEFAULT app_tenant_id() REFERENCES tenants (id) ON DELETE CASCADE,
  nombre      text NOT NULL,
  direccion   text,
  activa      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, tenant_id),
  UNIQUE (tenant_id, nombre)
);

-- 5.4 Usuarios (alumnos, colaboradores, operadores de pañol, administradores)
CREATE TABLE usuarios (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL DEFAULT app_tenant_id() REFERENCES tenants (id) ON DELETE CASCADE,
  sede_id            uuid,
  email              citext NOT NULL CHECK (position('@' IN email) > 1),
  nombre             text NOT NULL,
  rut_cifrado        bytea,          -- cifrado AES-256 en la aplicación (dato Crítico, sección 8.2)
  rol                rol_usuario NOT NULL DEFAULT 'alumno',
  password_hash      text,           -- Argon2/BCrypt; NULL si solo usa OAuth u OTP
  consentimiento_at  timestamptz,    -- opt-in de consentimiento informado (Plan R1)
  activo             boolean NOT NULL DEFAULT true,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, tenant_id),
  UNIQUE (tenant_id, email),
  FOREIGN KEY (sede_id, tenant_id) REFERENCES sedes (id, tenant_id) ON DELETE SET NULL (sede_id)
);

-- 5.5 Códigos OTP de contingencia (HU-01 CA3)
CREATE TABLE otp_codigos (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL DEFAULT app_tenant_id(),
  usuario_id   uuid NOT NULL,
  codigo_hash  text NOT NULL,        -- nunca guardar el código en texto plano
  expira_en    timestamptz NOT NULL DEFAULT now() + interval '5 minutes',
  usado        boolean NOT NULL DEFAULT false,
  intentos     smallint NOT NULL DEFAULT 0 CHECK (intentos >= 0),
  created_at   timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (usuario_id, tenant_id) REFERENCES usuarios (id, tenant_id) ON DELETE CASCADE
);

-- 5.6 Categorías de objetos
CREATE TABLE categorias (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL DEFAULT app_tenant_id() REFERENCES tenants (id) ON DELETE CASCADE,
  nombre       text NOT NULL,
  es_sensible  boolean NOT NULL DEFAULT false,   -- documentos/tarjetas: obliga a difuminar fotos
  activa       boolean NOT NULL DEFAULT true,
  UNIQUE (id, tenant_id),
  UNIQUE (tenant_id, nombre)
);

-- 5.7 Bienes enrolados preventivamente con QR (HU-03)
CREATE TABLE bienes_enrolados (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL DEFAULT app_tenant_id(),
  usuario_id    uuid NOT NULL,
  categoria_id  uuid NOT NULL,
  nombre        text NOT NULL,
  atributos     jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(atributos) = 'object'),
  qr_hash       text NOT NULL UNIQUE DEFAULT encode(gen_random_bytes(32), 'hex'),
  activo        boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, tenant_id),
  FOREIGN KEY (usuario_id, tenant_id)   REFERENCES usuarios (id, tenant_id) ON DELETE CASCADE,
  FOREIGN KEY (categoria_id, tenant_id) REFERENCES categorias (id, tenant_id)
);

-- 5.8 Objetos encontrados (HU-02)
CREATE TABLE objetos_encontrados (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL DEFAULT app_tenant_id(),
  sede_id             uuid NOT NULL,
  categoria_id        uuid NOT NULL,
  registrado_por      uuid NOT NULL,
  bien_enrolado_id    uuid,
  marca               text,
  modelo              text,
  color               text,
  ubicacion_hallazgo  text NOT NULL,
  fecha_hallazgo      timestamptz NOT NULL DEFAULT now(),
  atributos_publicos  jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(atributos_publicos) = 'object'),
  atributos_privados  jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(atributos_privados) = 'object'),
  estado              estado_objeto NOT NULL DEFAULT 'en_custodia',
  fecha_cierre        timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, tenant_id),
  FOREIGN KEY (sede_id, tenant_id)          REFERENCES sedes (id, tenant_id),
  FOREIGN KEY (categoria_id, tenant_id)     REFERENCES categorias (id, tenant_id),
  FOREIGN KEY (registrado_por, tenant_id)   REFERENCES usuarios (id, tenant_id),
  FOREIGN KEY (bien_enrolado_id, tenant_id) REFERENCES bienes_enrolados (id, tenant_id)
    ON DELETE SET NULL (bien_enrolado_id)
);

-- 5.9 Fotografías (archivos en Cloudflare R2)
CREATE TABLE fotos_objeto (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL DEFAULT app_tenant_id(),
  objeto_id   uuid NOT NULL,
  r2_key      text NOT NULL UNIQUE,
  es_publica  boolean NOT NULL DEFAULT false,
  difuminada  boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (objeto_id, tenant_id) REFERENCES objetos_encontrados (id, tenant_id) ON DELETE CASCADE
);

-- 5.10 Preguntas de desempate (HU-04 CA2)
CREATE TABLE preguntas_desempate (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL DEFAULT app_tenant_id(),
  objeto_id           uuid NOT NULL,
  pregunta            text NOT NULL,
  respuesta_esperada  text NOT NULL,   -- nunca se devuelve en endpoints públicos
  orden               smallint NOT NULL DEFAULT 1,
  UNIQUE (id, tenant_id),
  FOREIGN KEY (objeto_id, tenant_id) REFERENCES objetos_encontrados (id, tenant_id) ON DELETE CASCADE
);

-- 5.11 Reclamos (HU-04 / HU-05)
CREATE TABLE reclamos (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL DEFAULT app_tenant_id(),
  objeto_id          uuid NOT NULL,
  reclamante_id      uuid NOT NULL,
  evaluado_por       uuid,
  estado             estado_reclamo NOT NULL DEFAULT 'pendiente',
  intentos_fallidos  smallint NOT NULL DEFAULT 0 CHECK (intentos_fallidos >= 0),
  bloqueado_hasta    timestamptz,
  motivo_rechazo     text,
  evaluado_at        timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, tenant_id),
  UNIQUE (objeto_id, reclamante_id),
  FOREIGN KEY (objeto_id, tenant_id)     REFERENCES objetos_encontrados (id, tenant_id) ON DELETE CASCADE,
  FOREIGN KEY (reclamante_id, tenant_id) REFERENCES usuarios (id, tenant_id) ON DELETE CASCADE,
  FOREIGN KEY (evaluado_por, tenant_id)  REFERENCES usuarios (id, tenant_id) ON DELETE SET NULL (evaluado_por)
);

-- 5.12 Respuestas del reclamante a las preguntas de desempate
CREATE TABLE respuestas_reclamo (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL DEFAULT app_tenant_id(),
  reclamo_id   uuid NOT NULL,
  pregunta_id  uuid NOT NULL,
  respuesta    text NOT NULL,
  correcta     boolean,
  created_at   timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (reclamo_id, tenant_id)  REFERENCES reclamos (id, tenant_id) ON DELETE CASCADE,
  FOREIGN KEY (pregunta_id, tenant_id) REFERENCES preguntas_desempate (id, tenant_id) ON DELETE CASCADE
);

-- 5.13 Movimientos de custodia (cadena de custodia, inmutable)
CREATE TABLE movimientos_custodia (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL DEFAULT app_tenant_id(),
  objeto_id    uuid NOT NULL,
  usuario_id   uuid NOT NULL,
  sede_id      uuid NOT NULL,
  tipo         tipo_movimiento NOT NULL,
  observacion  text,
  fecha        timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (objeto_id, tenant_id)  REFERENCES objetos_encontrados (id, tenant_id),
  FOREIGN KEY (usuario_id, tenant_id) REFERENCES usuarios (id, tenant_id),
  FOREIGN KEY (sede_id, tenant_id)    REFERENCES sedes (id, tenant_id)
);

-- 5.14 Actas digitales de entrega (HU-05 CA2, inmutable)
CREATE TABLE actas_entrega (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL DEFAULT app_tenant_id(),
  reclamo_id            uuid NOT NULL UNIQUE,
  objeto_id             uuid NOT NULL,
  operador_id           uuid NOT NULL,
  receptor_id           uuid NOT NULL,
  rut_receptor_cifrado  bytea NOT NULL,
  firma_r2_key          text NOT NULL,      -- imagen de la firma en pantalla
  hash_sha256           char(64) NOT NULL,  -- calculado por trigger
  emitida_en            timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (reclamo_id, tenant_id)  REFERENCES reclamos (id, tenant_id),
  FOREIGN KEY (objeto_id, tenant_id)   REFERENCES objetos_encontrados (id, tenant_id),
  FOREIGN KEY (operador_id, tenant_id) REFERENCES usuarios (id, tenant_id),
  FOREIGN KEY (receptor_id, tenant_id) REFERENCES usuarios (id, tenant_id)
);

-- 5.15 Logs de auditoría (HU-05 CA3, inmutable)
CREATE TABLE logs_auditoria (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id   uuid NOT NULL DEFAULT app_tenant_id() REFERENCES tenants (id),
  usuario_id  uuid DEFAULT app_usuario_id(),   -- sin FK: el log sobrevive al usuario
  accion      text NOT NULL,
  entidad     text NOT NULL,
  entidad_id  uuid,
  metadata    jsonb NOT NULL DEFAULT '{}',
  ip          inet,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- =====================================================================
-- 6. ÍNDICES
-- =====================================================================
CREATE INDEX idx_tenant_dominios_tenant ON tenant_dominios (tenant_id);
CREATE INDEX idx_usuarios_sede          ON usuarios (tenant_id, sede_id);
CREATE INDEX idx_otp_vigentes           ON otp_codigos (usuario_id, expira_en) WHERE NOT usado;
CREATE INDEX idx_bienes_usuario         ON bienes_enrolados (usuario_id) WHERE activo;
CREATE INDEX idx_bienes_atributos       ON bienes_enrolados USING gin (atributos);
CREATE INDEX idx_objetos_catalogo       ON objetos_encontrados (tenant_id, estado, categoria_id, fecha_hallazgo DESC);
CREATE INDEX idx_objetos_sede           ON objetos_encontrados (tenant_id, sede_id);
CREATE INDEX idx_objetos_bien           ON objetos_encontrados (bien_enrolado_id) WHERE bien_enrolado_id IS NOT NULL;
CREATE INDEX idx_objetos_atrib_publicos ON objetos_encontrados USING gin (atributos_publicos);
CREATE INDEX idx_fotos_objeto           ON fotos_objeto (objeto_id);
CREATE INDEX idx_preguntas_objeto       ON preguntas_desempate (objeto_id);
CREATE INDEX idx_reclamos_reclamante    ON reclamos (reclamante_id);
CREATE INDEX idx_reclamos_pendientes    ON reclamos (tenant_id, created_at) WHERE estado = 'pendiente';
CREATE INDEX idx_respuestas_reclamo     ON respuestas_reclamo (reclamo_id);
CREATE INDEX idx_movimientos_objeto     ON movimientos_custodia (objeto_id, fecha);
CREATE INDEX idx_actas_objeto           ON actas_entrega (objeto_id);
CREATE INDEX idx_logs_tenant_fecha      ON logs_auditoria (tenant_id, created_at DESC);
CREATE INDEX idx_logs_entidad           ON logs_auditoria (entidad, entidad_id);

-- =====================================================================
-- 7. FUNCIONES Y TRIGGERS DE REGLAS DE NEGOCIO
-- =====================================================================

-- 7.1 updated_at automático
CREATE OR REPLACE FUNCTION trg_set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

CREATE TRIGGER tenants_updated_at   BEFORE UPDATE ON tenants             FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
CREATE TRIGGER usuarios_updated_at  BEFORE UPDATE ON usuarios            FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
CREATE TRIGGER bienes_updated_at    BEFORE UPDATE ON bienes_enrolados    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
CREATE TRIGGER objetos_updated_at   BEFORE UPDATE ON objetos_encontrados FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
CREATE TRIGGER reclamos_updated_at  BEFORE UPDATE ON reclamos            FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

-- 7.2 Inmutabilidad: actas, logs y movimientos no se modifican ni borran
CREATE OR REPLACE FUNCTION trg_bloquear_modificacion() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'La tabla % es inmutable: operación % no permitida', TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'insufficient_privilege';
END $$;

CREATE TRIGGER actas_inmutables       BEFORE UPDATE OR DELETE ON actas_entrega        FOR EACH ROW EXECUTE FUNCTION trg_bloquear_modificacion();
CREATE TRIGGER logs_inmutables        BEFORE UPDATE OR DELETE ON logs_auditoria       FOR EACH ROW EXECUTE FUNCTION trg_bloquear_modificacion();
CREATE TRIGGER movimientos_inmutables BEFORE UPDATE OR DELETE ON movimientos_custodia FOR EACH ROW EXECUTE FUNCTION trg_bloquear_modificacion();
CREATE TRIGGER actas_sin_truncate       BEFORE TRUNCATE ON actas_entrega        FOR EACH STATEMENT EXECUTE FUNCTION trg_bloquear_modificacion();
CREATE TRIGGER logs_sin_truncate        BEFORE TRUNCATE ON logs_auditoria       FOR EACH STATEMENT EXECUTE FUNCTION trg_bloquear_modificacion();
CREATE TRIGGER movimientos_sin_truncate BEFORE TRUNCATE ON movimientos_custodia FOR EACH STATEMENT EXECUTE FUNCTION trg_bloquear_modificacion();

-- 7.3 Límite de 30 bienes enrolados activos por usuario (HU-03 CA1)
CREATE OR REPLACE FUNCTION trg_limite_enrolamiento() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_total int;
BEGIN
  IF NEW.activo THEN
    -- Bloquea la fila del usuario para evitar que dos inserciones simultáneas superen el límite
    PERFORM 1 FROM usuarios WHERE id = NEW.usuario_id FOR UPDATE;
    SELECT count(*) INTO v_total
      FROM bienes_enrolados
     WHERE usuario_id = NEW.usuario_id AND activo AND id <> NEW.id;
    IF v_total >= 30 THEN
      RAISE EXCEPTION 'Límite alcanzado: máximo 30 bienes enrolados activos por usuario'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER bienes_limite_30
  BEFORE INSERT OR UPDATE OF activo, usuario_id ON bienes_enrolados
  FOR EACH ROW EXECUTE FUNCTION trg_limite_enrolamiento();

-- 7.4 Fotos de categorías sensibles deben estar difuminadas para ser públicas (HU-02 CA3)
CREATE OR REPLACE FUNCTION trg_validar_foto_sensible() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.es_publica AND NOT NEW.difuminada AND EXISTS (
       SELECT 1
         FROM objetos_encontrados o
         JOIN categorias c ON c.id = o.categoria_id
        WHERE o.id = NEW.objeto_id AND c.es_sensible) THEN
    RAISE EXCEPTION 'Las fotos de categorías sensibles deben difuminarse antes de publicarse'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER fotos_sensibles
  BEFORE INSERT OR UPDATE OF es_publica, difuminada ON fotos_objeto
  FOR EACH ROW EXECUTE FUNCTION trg_validar_foto_sensible();

-- 7.5 Todo objeto registrado genera su primer movimiento de custodia
CREATE OR REPLACE FUNCTION trg_objeto_ingreso() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO movimientos_custodia (tenant_id, objeto_id, usuario_id, sede_id, tipo, observacion)
  VALUES (NEW.tenant_id, NEW.id, NEW.registrado_por, NEW.sede_id, 'ingreso', 'Registro inicial en custodia');
  RETURN NULL;
END $$;

CREATE TRIGGER objetos_ingreso
  AFTER INSERT ON objetos_encontrados
  FOR EACH ROW EXECUTE FUNCTION trg_objeto_ingreso();

-- 7.6 Bloqueo por fuerza bruta: 3 fallos consecutivos = 24 h bloqueado (HU-04 CA3)
--     La API incrementa intentos_fallidos en cada intento erróneo y lo
--     vuelve a 0 cuando el reclamante acierta.
CREATE OR REPLACE FUNCTION trg_reclamo_control() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.intentos_fallidos >= 3 THEN
    NEW.bloqueado_hasta   := now() + interval '24 hours';
    NEW.intentos_fallidos := 0;
  END IF;
  IF NEW.estado IS DISTINCT FROM OLD.estado AND NEW.estado IN ('aprobado', 'rechazado') THEN
    NEW.evaluado_at := now();
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER reclamos_control
  BEFORE UPDATE ON reclamos
  FOR EACH ROW EXECUTE FUNCTION trg_reclamo_control();

-- 7.7 No se aceptan respuestas si el reclamo está bloqueado o la pregunta es de otro objeto
CREATE OR REPLACE FUNCTION trg_validar_respuesta() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM reclamos
              WHERE id = NEW.reclamo_id AND bloqueado_hasta > now()) THEN
    RAISE EXCEPTION 'Reclamo bloqueado temporalmente por intentos fallidos'
      USING ERRCODE = 'check_violation';
  END IF;
  IF NOT EXISTS (SELECT 1
                   FROM reclamos r
                   JOIN preguntas_desempate p ON p.objeto_id = r.objeto_id
                  WHERE r.id = NEW.reclamo_id AND p.id = NEW.pregunta_id) THEN
    RAISE EXCEPTION 'La pregunta no corresponde al objeto reclamado'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER respuestas_validar
  BEFORE INSERT ON respuestas_reclamo
  FOR EACH ROW EXECUTE FUNCTION trg_validar_respuesta();

-- 7.8 Auditoría automática de cambios de estado en reclamos (match / rechazo)
CREATE OR REPLACE FUNCTION trg_reclamo_auditoria() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO logs_auditoria (tenant_id, accion, entidad, entidad_id, metadata)
  VALUES (NEW.tenant_id, 'reclamo_' || NEW.estado, 'reclamos', NEW.id,
          jsonb_build_object('estado_anterior', OLD.estado,
                             'objeto_id',       NEW.objeto_id,
                             'evaluado_por',    NEW.evaluado_por));
  RETURN NULL;
END $$;

CREATE TRIGGER reclamos_auditoria
  AFTER UPDATE OF estado ON reclamos
  FOR EACH ROW WHEN (NEW.estado IS DISTINCT FROM OLD.estado)
  EXECUTE FUNCTION trg_reclamo_auditoria();

-- 7.9 Acta: valida el reclamo y sella el contenido con SHA-256 (HU-05 CA2)
CREATE OR REPLACE FUNCTION trg_acta_validar_y_sellar() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  r reclamos%ROWTYPE;
BEGIN
  SELECT * INTO r FROM reclamos WHERE id = NEW.reclamo_id;

  IF NOT FOUND OR r.estado <> 'aprobado' THEN
    RAISE EXCEPTION 'Solo se puede emitir un acta para un reclamo aprobado'
      USING ERRCODE = 'check_violation';
  END IF;

  IF r.objeto_id <> NEW.objeto_id OR r.reclamante_id <> NEW.receptor_id THEN
    RAISE EXCEPTION 'El acta no coincide con el objeto o el reclamante del reclamo'
      USING ERRCODE = 'check_violation';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM usuarios
                  WHERE id = NEW.operador_id AND rol IN ('operador', 'admin_tenant')) THEN
    RAISE EXCEPTION 'Solo un operador o administrador puede emitir actas'
      USING ERRCODE = 'check_violation';
  END IF;

  IF EXISTS (SELECT 1 FROM objetos_encontrados
              WHERE id = NEW.objeto_id AND estado = 'entregado') THEN
    RAISE EXCEPTION 'El objeto ya fue entregado'
      USING ERRCODE = 'check_violation';
  END IF;

  NEW.emitida_en  := now();
  NEW.hash_sha256 := encode(digest(concat_ws('|',
      NEW.id, NEW.tenant_id, NEW.reclamo_id, NEW.objeto_id,
      NEW.operador_id, NEW.receptor_id,
      encode(NEW.rut_receptor_cifrado, 'hex'),
      NEW.firma_r2_key,
      to_char(NEW.emitida_en AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
    ), 'sha256'), 'hex');

  RETURN NEW;
END $$;

CREATE TRIGGER actas_validar_y_sellar
  BEFORE INSERT ON actas_entrega
  FOR EACH ROW EXECUTE FUNCTION trg_acta_validar_y_sellar();

-- 7.10 Acta emitida: cierra la custodia, registra movimiento y log
CREATE OR REPLACE FUNCTION trg_acta_cerrar_custodia() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_sede uuid;
BEGIN
  UPDATE objetos_encontrados
     SET estado = 'entregado', fecha_cierre = NEW.emitida_en
   WHERE id = NEW.objeto_id
  RETURNING sede_id INTO v_sede;

  INSERT INTO movimientos_custodia (tenant_id, objeto_id, usuario_id, sede_id, tipo, observacion)
  VALUES (NEW.tenant_id, NEW.objeto_id, NEW.operador_id, v_sede, 'entrega', 'Acta ' || NEW.id);

  INSERT INTO logs_auditoria (tenant_id, usuario_id, accion, entidad, entidad_id, metadata)
  VALUES (NEW.tenant_id, NEW.operador_id, 'entrega_acta', 'actas_entrega', NEW.id,
          jsonb_build_object('objeto_id', NEW.objeto_id,
                             'receptor_id', NEW.receptor_id,
                             'hash', NEW.hash_sha256));
  RETURN NULL;
END $$;

CREATE TRIGGER actas_cerrar_custodia
  AFTER INSERT ON actas_entrega
  FOR EACH ROW EXECUTE FUNCTION trg_acta_cerrar_custodia();

-- 7.11 Resolución de tenant por dominio de correo (HU-01 CA1)
--      SECURITY DEFINER: se ejecuta antes de conocer el tenant, por eso
--      corre con permisos del owner. Solo devuelve el uuid, nada más.
CREATE OR REPLACE FUNCTION resolver_tenant_por_email(p_email text) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT d.tenant_id
    FROM tenant_dominios d
    JOIN tenants t ON t.id = d.tenant_id
   WHERE d.dominio = lower(split_part(p_email, '@', 2))::citext
     AND t.estado <> 'suspendido'
$$;

-- =====================================================================
-- 8. ROW-LEVEL SECURITY (Capa 1 de defensa, sección 8.3 del informe)
--    FORCE aplica RLS incluso al dueño de la tabla.
--    Sin app.tenant_id definido, las consultas no devuelven filas.
-- =====================================================================

-- tenants: la app solo puede leer su propio tenant
ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_propio ON tenants
  FOR SELECT USING (id = app_tenant_id());

-- tenant_dominios: sin políticas; solo accesible vía resolver_tenant_por_email()
ALTER TABLE tenant_dominios ENABLE ROW LEVEL SECURITY;

ALTER TABLE sedes ENABLE ROW LEVEL SECURITY;
ALTER TABLE sedes FORCE ROW LEVEL SECURITY;
CREATE POLICY aislamiento_tenant ON sedes
  USING (tenant_id = app_tenant_id()) WITH CHECK (tenant_id = app_tenant_id());

ALTER TABLE usuarios ENABLE ROW LEVEL SECURITY;
ALTER TABLE usuarios FORCE ROW LEVEL SECURITY;
CREATE POLICY aislamiento_tenant ON usuarios
  USING (tenant_id = app_tenant_id()) WITH CHECK (tenant_id = app_tenant_id());

ALTER TABLE otp_codigos ENABLE ROW LEVEL SECURITY;
ALTER TABLE otp_codigos FORCE ROW LEVEL SECURITY;
CREATE POLICY aislamiento_tenant ON otp_codigos
  USING (tenant_id = app_tenant_id()) WITH CHECK (tenant_id = app_tenant_id());

ALTER TABLE categorias ENABLE ROW LEVEL SECURITY;
ALTER TABLE categorias FORCE ROW LEVEL SECURITY;
CREATE POLICY aislamiento_tenant ON categorias
  USING (tenant_id = app_tenant_id()) WITH CHECK (tenant_id = app_tenant_id());

ALTER TABLE bienes_enrolados ENABLE ROW LEVEL SECURITY;
ALTER TABLE bienes_enrolados FORCE ROW LEVEL SECURITY;
CREATE POLICY aislamiento_tenant ON bienes_enrolados
  USING (tenant_id = app_tenant_id()) WITH CHECK (tenant_id = app_tenant_id());

ALTER TABLE objetos_encontrados ENABLE ROW LEVEL SECURITY;
ALTER TABLE objetos_encontrados FORCE ROW LEVEL SECURITY;
CREATE POLICY aislamiento_tenant ON objetos_encontrados
  USING (tenant_id = app_tenant_id()) WITH CHECK (tenant_id = app_tenant_id());

ALTER TABLE fotos_objeto ENABLE ROW LEVEL SECURITY;
ALTER TABLE fotos_objeto FORCE ROW LEVEL SECURITY;
CREATE POLICY aislamiento_tenant ON fotos_objeto
  USING (tenant_id = app_tenant_id()) WITH CHECK (tenant_id = app_tenant_id());

ALTER TABLE preguntas_desempate ENABLE ROW LEVEL SECURITY;
ALTER TABLE preguntas_desempate FORCE ROW LEVEL SECURITY;
CREATE POLICY aislamiento_tenant ON preguntas_desempate
  USING (tenant_id = app_tenant_id()) WITH CHECK (tenant_id = app_tenant_id());

ALTER TABLE reclamos ENABLE ROW LEVEL SECURITY;
ALTER TABLE reclamos FORCE ROW LEVEL SECURITY;
CREATE POLICY aislamiento_tenant ON reclamos
  USING (tenant_id = app_tenant_id()) WITH CHECK (tenant_id = app_tenant_id());

ALTER TABLE respuestas_reclamo ENABLE ROW LEVEL SECURITY;
ALTER TABLE respuestas_reclamo FORCE ROW LEVEL SECURITY;
CREATE POLICY aislamiento_tenant ON respuestas_reclamo
  USING (tenant_id = app_tenant_id()) WITH CHECK (tenant_id = app_tenant_id());

ALTER TABLE movimientos_custodia ENABLE ROW LEVEL SECURITY;
ALTER TABLE movimientos_custodia FORCE ROW LEVEL SECURITY;
CREATE POLICY aislamiento_tenant ON movimientos_custodia
  USING (tenant_id = app_tenant_id()) WITH CHECK (tenant_id = app_tenant_id());

ALTER TABLE actas_entrega ENABLE ROW LEVEL SECURITY;
ALTER TABLE actas_entrega FORCE ROW LEVEL SECURITY;
CREATE POLICY aislamiento_tenant ON actas_entrega
  USING (tenant_id = app_tenant_id()) WITH CHECK (tenant_id = app_tenant_id());

ALTER TABLE logs_auditoria ENABLE ROW LEVEL SECURITY;
ALTER TABLE logs_auditoria FORCE ROW LEVEL SECURITY;
CREATE POLICY aislamiento_tenant ON logs_auditoria
  USING (tenant_id = app_tenant_id()) WITH CHECK (tenant_id = app_tenant_id());

-- =====================================================================
-- 9. PERMISOS DEL ROL DE LA APLICACIÓN (mínimo privilegio)
-- =====================================================================
GRANT USAGE ON SCHEMA public TO backtome_app;

GRANT SELECT ON tenants TO backtome_app;

GRANT SELECT, INSERT, UPDATE, DELETE ON
  sedes, usuarios, otp_codigos, categorias, bienes_enrolados,
  objetos_encontrados, fotos_objeto, preguntas_desempate,
  reclamos, respuestas_reclamo
TO backtome_app;

-- Tablas inmutables: solo lectura e inserción
GRANT SELECT, INSERT ON actas_entrega, logs_auditoria, movimientos_custodia TO backtome_app;

GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO backtome_app;

REVOKE ALL ON FUNCTION resolver_tenant_por_email(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION resolver_tenant_por_email(text) TO backtome_app;

COMMIT;
