-- FIZZAROLLIO: выдача уникального артефакта за правильный ответ на загадку в ДРОП.
-- Существующая модель cards и уникальность owner_id/email_norm не меняются.

create or replace function public.claim_card_from_riddle(p_day integer, p_answer text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  c public.cards;
  answer_result jsonb;
  r numeric := random() * 100;
  rar text;
  ser text;
  ttl text;
  idx_s int;
  tries int := 0;
  em text;
  cf timestamptz;
  en text;
  pre text[] := array['ПОСЛЕДНИЙ','НЕИЗВЕСТНЫЙ','ПОВРЕЖДЁННЫЙ','ТРЕТИЙ','ЗАБЫТЫЙ','ТИХИЙ','СКРЫТЫЙ','ПЕРВЫЙ','ЦИФРОВОЙ','ЛИШНИЙ'];
  noun text[] := array['НАБЛЮДАТЕЛЬ','ОБЪЕКТ','СИГНАЛ','СБОЙ','СЛЕД','АРХИВ','ОБРАЗ','КОД','ШЁПОТ','АРТЕФАКТ','ОТПЕЧАТОК','ГОСТЬ'];
  anom text[] := array['СБОЙ В РЕАЛЬНОСТИ','ЭТОГО НЕ БЫЛО','ОШИБКА ГЛАВНОГО ГЕРОЯ','ФАЙЛ, КОТОРОГО НЕТ'];
  descr text[] := array[
    'Он видел тебя раньше. Просто ты не заметил.',
    'Найден там, где ломается тишина.',
    'Не оригинал. Не копия. Что-то между.',
    'Система не знает, как его назвать.',
    'Помехи — это тоже язык.',
    'Хранится в архиве, которого не существует.',
    'Появился в момент сбоя и не исчез.',
    'Тот, кто нашёл его, уже не совсем тот же.',
    'Сигнал дошёл. Адресат неизвестен.',
    'Не смотри на него слишком долго.',
    'Остался после стёртого файла.',
    'Он ждал именно тебя.',
    'Фрагмент системы, которой здесь нет.',
    'Если он светится — значит, он помнит.',
    'Не ошибка. Просто не по плану.',
    'Ты был здесь. Он это зафиксировал.'
  ];
  syms text[] := array['ЗВЕЗДА','ГЛАЗ','КРЕСТ','СЕРДЦЕ','УЗЕЛ','ТРЕУГОЛЬНИК','МОЛНИЯ','КОЛЬЦО','РАЗЛОМ','ПРИЦЕЛ','ВОЛНА','ЗНАК FZ'];
begin
  if uid is null or coalesce((auth.jwt()->>'is_anonymous')::boolean, false) then
    raise exception 'AUTH_REQUIRED';
  end if;

  select u.email, u.email_confirmed_at into em, cf
    from auth.users u where u.id = uid;
  if em is null or cf is null then raise exception 'AUTH_REQUIRED'; end if;

  -- Проверка ответа выполняется на сервере; клиент не может сам объявить ответ правильным.
  answer_result := public.ud_drop_answer(p_day, p_answer);
  if coalesce((answer_result->>'ok')::boolean, false) is false then
    return answer_result;
  end if;
  if coalesce((answer_result->>'correct')::boolean, false) is false then
    return jsonb_build_object('correct', false);
  end if;

  en := public._email_norm(em);
  select * into c from public.cards where owner_id = uid;
  if found then
    return jsonb_build_object(
      'correct', true,
      'card', to_jsonb(c) - 'owner_id' - 'id' - 'email_norm',
      'is_new', false,
      'meaning', answer_result->>'meaning'
    );
  end if;

  if exists (select 1 from public.cards x where x.email_norm = en and x.owner_id <> uid) then
    raise exception 'EMAIL_ALREADY_CLAIMED';
  end if;
  if not public.fz_rate('claim', 8, 600) then
    return jsonb_build_object('ok', false, 'error', 'RATE_LIMIT');
  end if;

  rar := case
    when r < 1 then 'ANOMALY'
    when r < 6 then 'LEGENDARY'
    when r < 15 then 'EPIC'
    when r < 30 then 'RARE'
    when r < 55 then 'UNCOMMON'
    else 'COMMON'
  end;

  loop
    tries := tries + 1;
    ser := 'FZ-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,5))
               || '-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,5));
    if rar = 'ANOMALY' then
      ttl := anom[1 + floor(random() * array_length(anom,1))::int];
    else
      ttl := pre[1 + floor(random() * array_length(pre,1))::int]
             || ' ' || noun[1 + floor(random() * array_length(noun,1))::int];
    end if;
    idx_s := floor(random() * 12)::int;
    begin
      insert into public.cards (owner_id, email_norm, serial_number, rarity, title, description, symbol, traits)
      values (
        uid, en, ser, rar, ttl,
        descr[1 + floor(random() * array_length(descr,1))::int],
        syms[idx_s + 1],
        jsonb_build_object(
          'c', floor(random()*12)::int,
          'b', floor(random()*10)::int,
          's', idx_s,
          'p', floor(random()*12)::int,
          'x', floor(random()*1000000000)::bigint
        )
      )
      returning * into c;

      insert into public.security_log (event, meta)
      values ('card_issued', jsonb_build_object('rarity', rar, 'source', 'drop_riddle'));

      return jsonb_build_object(
        'correct', true,
        'card', to_jsonb(c) - 'owner_id' - 'id' - 'email_norm',
        'is_new', true,
        'meaning', answer_result->>'meaning'
      );
    exception when unique_violation then
      select * into c from public.cards where owner_id = uid;
      if found then
        return jsonb_build_object(
          'correct', true,
          'card', to_jsonb(c) - 'owner_id' - 'id' - 'email_norm',
          'is_new', false,
          'meaning', answer_result->>'meaning'
        );
      end if;
      if exists (select 1 from public.cards x where x.email_norm = en) then
        raise exception 'EMAIL_ALREADY_CLAIMED';
      end if;
      if tries >= 8 then raise exception 'RETRY_LIMIT'; end if;
    end;
  end loop;
end;
$$;

revoke all on function public.claim_card(text) from public, anon, authenticated;
revoke all on function public.claim_card_from_riddle(integer, text) from public, anon;
grant execute on function public.claim_card_from_riddle(integer, text) to authenticated;
